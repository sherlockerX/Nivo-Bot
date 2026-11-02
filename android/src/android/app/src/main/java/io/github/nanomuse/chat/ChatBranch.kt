package io.github.nanomuse.chat

import com.openminis.app.data.repository.ChatRepository
import java.util.UUID

/**
 * Mosaic: "Branch from here" on a reply. A new chat that holds the conversation up to the end
 * of that reply's turn, so a side topic can be followed without touching the original thread.
 * The stored rows are copied as they are, tool calls and results included, so the model sees
 * the same history; token counts stay with the original chat.
 */
object ChatBranch {

    /**
     * Copies [sessionId]'s rows that come before its ([userTurns] + 1)-th message from the person
     * into a new chat named [title], with the same model, memory switch and thinking choice. Like
     * every new chat it starts Ungrouped; the owner files it. Returns the new chat's id, or null
     * when there is nothing to copy.
     */
    suspend fun create(repo: ChatRepository, sessionId: String, userTurns: Int, title: String): String? {
        val source = repo.getSession(sessionId) ?: return null
        val rows = repo.loadMessages(sessionId)
        var seen = 0
        var cut = rows.size
        for ((i, row) in rows.withIndex()) {
            if (!row.role.equals("user", ignoreCase = true) || !isPersonsMessage(row.partsJson)) continue
            if (seen == userTurns) {
                cut = i
                break
            }
            seen++
        }
        val kept = rows.subList(0, cut)
        if (kept.isEmpty()) return null

        val branch = repo.createSession(modelId = source.modelId, title = title, memoryEnabled = source.memoryEnabled != 0)
        source.modelBinding?.let { repo.updateSessionBinding(branch.id, it, source.modelId) }
        source.thinkingOverride?.let { repo.dao.updateThinkingOverride(branch.id, it) }
        for (row in kept) {
            repo.dao.insertMessage(row.copy(id = UUID.randomUUID().toString(), sessionId = branch.id, tokenUsage = null))
        }
        repo.updateSessionPreview(branch.id, kept.last().partsJson)
        return branch.id
    }

    /**
     * A row the chat shows as a message from the person: words or a picture. Tool results and
     * the agent's own "continue" reminder are user rows too, but no bubble; the same rule as
     * ChatViewModel.retryFromMessage, plus pictures sent without words.
     */
    private fun isPersonsMessage(partsJson: String): Boolean {
        val parts = runCatching { org.json.JSONArray(partsJson) }.getOrNull() ?: return true
        return (0 until parts.length()).any { i ->
            val part = parts.optJSONObject(i) ?: return@any false
            when (part.optString("type")) {
                "text" -> part.optString("value").let { it.isNotBlank() && !it.trimStart().startsWith("<system-reminder>") }
                "mediaRef" -> true
                else -> false
            }
        }
    }
}
