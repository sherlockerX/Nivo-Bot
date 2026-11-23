package io.github.nanomuse.chat

import com.openminis.app.data.db.CompactMarkerEntity
import com.openminis.app.data.db.MessageEntity
import com.openminis.app.data.repository.ChatRepository
import org.json.JSONArray

/**
 * 打开对话时从哪一行开始读。
 *
 * 没有压缩过的对话，模型需要完整历史，从头读。压缩过的对话，模型只用摘要、压缩点前的近期轮次和之后的内容，
 * 更早的记录留在磁盘上，上滑或需要完整记录的操作再读。起点总在一条真正的用户消息上，不会拆开一轮回复和它的工具结果。
 */
internal object TranscriptWindow {
    /** 压缩点之前保留的行数，多于模型会用到的近期轮次上限（100条）。 */
    private const val ROWS_BEFORE_ANCHOR = 130

    /** 不论压缩点在哪，至少读这么多行。 */
    private const val RECENT_ROWS = 300

    /** 留在磁盘上的行数太少就不值得分段。 */
    private const val MIN_SKIPPED_ROWS = 100

    /** 上滑一次补读的行数。 */
    private const val OLDER_ROWS = 200

    private const val SCAN_ROWS = 40

    /** 首次打开的起点；0表示读整段。 */
    suspend fun start(repository: ChatRepository, sessionId: String, marker: CompactMarkerEntity?): Int {
        val anchor = marker?.takeIf { it.version >= 2 }?.lastCompactedMessageId?.ifEmpty { null } ?: return 0
        val total = repository.dao.messageCountForSession(sessionId)
        val anchorRow = repository.dao.nmRowsBefore(sessionId, anchor)
        val wanted = minOf(anchorRow - ROWS_BEFORE_ANCHOR, total - RECENT_ROWS)
        if (wanted < MIN_SKIPPED_ROWS) return 0
        return turnStart(repository, sessionId, wanted)
    }

    /** 已经读到第[end]行时，再往前一页的起点。 */
    suspend fun olderStart(repository: ChatRepository, sessionId: String, end: Int): Int =
        if (end <= OLDER_ROWS + MIN_SKIPPED_ROWS) 0 else turnStart(repository, sessionId, end - OLDER_ROWS)

    /** [row]及之前最近的一条用户消息；一直找不到就从头读。 */
    private suspend fun turnStart(repository: ChatRepository, sessionId: String, row: Int): Int {
        var end = row + 1
        while (end > 0) {
            val start = (end - SCAN_ROWS).coerceAtLeast(0)
            val rows = repository.loadMessageRange(sessionId, start, end)
            // 有读不出的行时行号对不上，退回整段读取。
            if (rows.size != end - start) return 0
            val found = rows.indexOfLast(::isUserTurn)
            if (found >= 0) return start + found
            end = start
        }
        return 0
    }

    /** 用户自己发的消息；工具结果和系统提醒也存成用户角色，不算。 */
    private fun isUserTurn(row: MessageEntity): Boolean {
        if (row.role != "user" || row.partsJson.contains("<system-reminder>")) return false
        return try {
            val parts = JSONArray(row.partsJson)
            val types = (0 until parts.length()).map { parts.optJSONObject(it)?.optString("type") }
            types.isNotEmpty() && types.none { it == "toolResult" }
        } catch (_: org.json.JSONException) {
            false
        }
    }
}
