package io.github.nanomuse.routines

import java.io.BufferedInputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import org.json.JSONObject

/** 只监听IPv4回环地址的最小SSE提供商，记录路径与模型，不记录头部或凭据。 */
internal class ScheduledLoopbackProvider : AutoCloseable {
    private val server = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
    private val requests = LinkedBlockingQueue<Request>()
    @Volatile private var failure: Throwable? = null
    private val thread = Thread({ serve() }, "scheduled-loopback-fixture").apply { isDaemon = true; start() }

    /** 与两个测试提供商共用端口，以路径区分实际路由。 */
    fun baseUrl(route: String): String = "http://127.0.0.1:${server.localPort}/$route/v1"

    /** 请求没有到达时显示服务端失败，不通过外网补偿。 */
    fun take(): Request = requests.poll(5, TimeUnit.SECONDS)
        ?: throw AssertionError("本地提供商未收到请求", failure)

    /** 关闭监听并等待后台线程，夹具不得残留到下一个测试。 */
    override fun close() { server.close(); thread.join(5_000) }

    private fun serve() {
        while (!server.isClosed) {
            try { server.accept().use(::reply) }
            catch (error: Exception) { if (!server.isClosed) failure = error }
        }
    }

    private fun reply(socket: Socket) {
        socket.soTimeout = 5_000
        val input = BufferedInputStream(socket.getInputStream())
        val requestLine = readLine(input)
        var length = 0
        repeat(80) {
            val line = readLine(input)
            if (line.isEmpty()) {
                require(length in 1..32_768)
                val body = ByteArray(length)
                var offset = 0
                while (offset < length) {
                    val count = input.read(body, offset, length - offset)
                    check(count > 0)
                    offset += count
                }
                val json = JSONObject(body.toString(Charsets.UTF_8))
                requests.add(Request(requestLine.split(' ')[1], json.getString("model")))
                writeResponse(socket)
                return
            }
            if (line.startsWith("Content-Length:", ignoreCase = true)) length = line.substringAfter(':').trim().toInt()
        }
        error("本地请求头超过夹具上限")
    }

    private fun readLine(input: BufferedInputStream): String {
        val result = StringBuilder()
        repeat(8_192) {
            val value = input.read()
            check(value >= 0)
            if (value == 10) return result.toString().removeSuffix("\r")
            result.append(value.toChar())
        }
        error("本地请求行超过夹具上限")
    }

    private fun writeResponse(socket: Socket) {
        val body = "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"fixture-ok\"},\"finish_reason\":null}]}\n\n" +
            "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" +
            "data: [DONE]\n\n"
        val bytes = body.toByteArray(Charsets.UTF_8)
        val headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n"
        socket.getOutputStream().apply { write(headers.toByteArray(Charsets.US_ASCII)); write(bytes); flush() }
    }

    /** 只保留合成请求的非敏感路由信息。 */
    data class Request(val path: String, val model: String)
}
