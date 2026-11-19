package io.github.nanomuse.chat

import java.io.BufferedInputStream
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import org.json.JSONArray
import org.json.JSONObject

/** nanoMuse: 仅监听IPv4回环的合成模型，保存实际请求正文并按测试脚本返回SSE。 */
internal class PersonalRecordsLoopbackProvider(private val evidenceFile: File? = null) : AutoCloseable {
    private val server = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
    private val replies = LinkedBlockingQueue<Reply>()
    private val requests = LinkedBlockingQueue<Request>()
    private val gates = mutableListOf<CountDownLatch>()
    private var requestCount = 0
    @Volatile private var failure: Throwable? = null
    @Volatile private var activeSocket: Socket? = null
    private val thread = Thread(::serve, "records-chat-loopback").apply {
        isDaemon = true
        start()
    }

    /** 唯一可用地址不接受外部主机，也不需要真实API凭据。 */
    val baseUrl: String get() = "http://127.0.0.1:${server.localPort}/v1"

    /** 暂停响应可稳定覆盖真实发送中的入队与后台继续，避免依赖短暂时序。 */
    fun enqueueText(text: String = "fixture-complete", hold: Boolean = false): CountDownLatch {
        val gate = CountDownLatch(if (hold) 1 else 0)
        gates.add(gate)
        replies.add(Reply(JSONObject().put("content", text), "stop", gate))
        return gate
    }

    /** 工具参数仅包含当前测试创建的专注ID；工具结果由真实VM执行后回传。 */
    fun enqueueFocusQuery(targetId: String, callId: String, hold: Boolean = false): CountDownLatch {
        val gate = CountDownLatch(if (hold) 1 else 0)
        gates.add(gate)
        val arguments = JSONObject().put("kind", "detail").put("targetId", targetId)
        val function = JSONObject().put("name", "focus_query").put("arguments", arguments.toString())
        val call = JSONObject().put("index", 0).put("id", callId)
            .put("type", "function").put("function", function)
        replies.add(Reply(JSONObject().put("tool_calls", JSONArray().put(call)),
            "tool_calls", gate))
        return gate
    }

    /** 在测试线程等待，主线程与真实模型循环保持运行。 */
    fun take(): Request = requests.poll(30, TimeUnit.SECONDS)
        ?: throw AssertionError("普通聊天未向回环服务发送请求", failure)

    /** 清理同时释放所有响应闸门和活动连接，断言失败也不会遗留服务线程。 */
    override fun close() {
        gates.forEach { it.countDown() }
        server.close()
        activeSocket?.close()
        thread.join(5_000)
        check(!thread.isAlive) { "回环提供商线程未停止" }
    }

    private fun serve() {
        while (!server.isClosed) {
            try {
                server.accept().use { socket ->
                    activeSocket = socket
                    reply(socket)
                }
            } catch (error: Exception) {
                if (!server.isClosed) failure = error
            } finally {
                activeSocket = null
            }
        }
    }

    private fun reply(socket: Socket) {
        socket.soTimeout = 10_000
        val input = BufferedInputStream(socket.getInputStream())
        val requestLine = readLine(input)
        val length = readLength(input)
        val path = requestLine.split(' ')[1]
        // 模型目录的后台刷新也只能到本机，且不能消费聊天响应脚本。
        if (requestLine.startsWith("GET ") && path == "/v1/models") {
            writeResponse(socket, "application/json", "{\"object\":\"list\",\"data\":[" +
                "{\"id\":\"fixture-personal-records\",\"object\":\"model\"}]}")
            return
        }
        require(requestLine.startsWith("POST ") && path == "/v1/chat/completions")
        val body = readBody(input, length)
        val request = Request(path, JSONObject(body))
        requestCount++
        evidenceFile?.appendText(request.summary().put("requestIndex", requestCount).toString() + "\n")
        requests.add(request)
        val plan = checkNotNull(replies.poll()) { "意外的额外模型请求" }
        check(plan.gate.await(30, TimeUnit.SECONDS)) { "测试未释放响应闸门" }
        val chunk = JSONObject().put("choices", JSONArray().put(JSONObject().put("index", 0)
            .put("delta", plan.delta).put("finish_reason", JSONObject.NULL)))
        val finish = JSONObject().put("choices", JSONArray().put(JSONObject().put("index", 0)
            .put("delta", JSONObject()).put("finish_reason", plan.finishReason)))
        writeResponse(socket, "text/event-stream", "data: $chunk\n\ndata: $finish\n\ndata: [DONE]\n\n")
    }

    private fun readLength(input: BufferedInputStream): Int {
        var length = 0
        repeat(80) {
            val line = readLine(input)
            if (line.isEmpty()) return length
            if (line.startsWith("Content-Length:", ignoreCase = true)) {
                length = line.substringAfter(':').trim().toInt()
            }
        }
        error("请求头超过夹具上限")
    }

    private fun readBody(input: BufferedInputStream, length: Int): String {
        require(length in 1..2_097_152)
        val body = ByteArray(length)
        var offset = 0
        while (offset < length) {
            val count = input.read(body, offset, length - offset)
            check(count > 0) { "请求正文提前结束" }
            offset += count
        }
        return body.toString(Charsets.UTF_8)
    }

    private fun readLine(input: BufferedInputStream): String {
        val result = StringBuilder()
        repeat(8_192) {
            val value = input.read()
            check(value >= 0)
            if (value == 10) return result.toString().removeSuffix("\r")
            result.append(value.toChar())
        }
        error("请求行超过夹具上限")
    }

    private fun writeResponse(socket: Socket, contentType: String, body: String) {
        val bytes = body.toByteArray(Charsets.UTF_8)
        val headers = "HTTP/1.1 200 OK\r\nContent-Type: $contentType\r\n" +
            "Content-Length: ${bytes.size}\r\nConnection: close\r\n\r\n"
        socket.getOutputStream().apply {
            write(headers.toByteArray(Charsets.US_ASCII))
            write(bytes)
            flush()
        }
    }

    /** 只保留测试会话的正文，不采集请求头或凭据。 */
    data class Request(val path: String, val body: JSONObject) {
        /** 保留路由、schema及工具结果结构，不写请求头、密钥或完整系统提示。 */
        fun summary(): JSONObject {
            val messages = body.optJSONArray("messages") ?: JSONArray()
            val messageSummaries = JSONArray()
            for (index in 0 until messages.length()) {
                val message = messages.getJSONObject(index)
                val content = message.optString("content")
                val item = JSONObject().put("role", message.optString("role"))
                    .put("contentLength", content.length)
                if (message.optString("role") == "tool") {
                    item.put("toolCallId", message.optString("tool_call_id"))
                    val result = runCatching { JSONObject(content) }.getOrNull()
                    item.put("success", result?.opt("success") ?: JSONObject.NULL)
                    val record = result?.optJSONObject("data")
                    item.put("recordId", record?.opt("id") ?: JSONObject.NULL)
                    item.put("elapsedMs", record?.opt("elapsedMs") ?: JSONObject.NULL)
                    item.put("status", record?.opt("status") ?: JSONObject.NULL)
                }
                messageSummaries.put(item)
            }
            return JSONObject().put("kind", "provider_request").put("path", path)
                .put("model", body.optString("model")).put("tools", JSONArray(toolNames().sorted()))
                .put("messages", messageSummaries)
        }

        /** 从真实OpenAI兼容请求读取声明的函数名。 */
        fun toolNames(): Set<String> {
            val tools = body.optJSONArray("tools") ?: return emptySet()
            return (0 until tools.length()).map {
                tools.getJSONObject(it).getJSONObject("function").getString("name")
            }.toSet()
        }

        /** 按工具调用ID定位模型实际收到的结果，而非直接调用工具桥。 */
        fun toolResult(callId: String): JSONObject {
            val messages = body.getJSONArray("messages")
            val message = (0 until messages.length()).map(messages::getJSONObject).single {
                it.optString("role") == "tool" && it.optString("tool_call_id") == callId
            }
            return JSONObject(message.getString("content"))
        }
    }

    /** 每条响应只有一个脚本，避免自动重试掩盖错误的请求数量。 */
    private data class Reply(val delta: JSONObject, val finishReason: String, val gate: CountDownLatch)
}
