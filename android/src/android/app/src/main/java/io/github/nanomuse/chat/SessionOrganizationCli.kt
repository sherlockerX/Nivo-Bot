package io.github.nanomuse.chat

import com.openminis.app.data.repository.ChatRepository
import com.openminis.app.sandbox.offload.OffloadArgs
import org.json.JSONArray
import org.json.JSONObject

/** 复用已有分组数据，解散分组不删除任何对话。 */
internal object SessionOrganizationCli {
    /** 执行分组和置顶命令，所有ID均在写入前验证。 */
    suspend fun execute(repo: ChatRepository, args: OffloadArgs): JSONObject = when (args.positional.first()) {
        "groups" -> groups(repo, args)
        "move" -> {
            val session = requireNotNull(repo.getSession(required(args, "id"))) { "Session not found" }
            val group = required(args, "group").takeUnless { it == "none" }
            require(group == null || repo.dao.getFolder(group) != null) { "Group not found" }
            repo.setFolderForSessions(group, listOf(session.id))
            JSONObject().put("session_id", session.id).put("group_id", group ?: JSONObject.NULL)
        }
        "pin" -> {
            val session = requireNotNull(repo.getSession(required(args, "id"))) { "Session not found" }
            val isPinned = !args.hasFlag("unpin")
            repo.dao.updatePinnedAt(session.id, if (isPinned) System.currentTimeMillis() else null)
            JSONObject().put("session_id", session.id).put("pinned", isPinned)
        }
        "archive", "unarchive" -> archive(repo, args, args.positional.first() == "archive")
        else -> error("Unsupported organization command")
    }

    /**
     * Mosaic: 归档就是“定时任务”系统分组：侧栏默认收起，list 默认不列，消息不动；unarchive 放回未分组。
     * 只收定时任务建的会话，组名才名副其实。
     */
    private suspend fun archive(repo: ChatRepository, args: OffloadArgs, archive: Boolean): JSONObject {
        val ids = required(args, "id").split(",").map { it.trim() }.filter { it.isNotEmpty() }
        val sessions = ids.map { id -> requireNotNull(repo.getSession(id)) { "Session not found: $id" } }
        if (archive) {
            require(sessions.all { it.source == "scheduled" || it.createdByTaskId != null }) { "Only conversations made by scheduled tasks can be archived" }
            if (repo.dao.getFolder(GroupNamePolicy.SYSTEM_ID) == null)
                runCatching { repo.dao.insertFolder(io.github.nanomuse.routines.ScheduledConversationGroup.folder()) }
        }
        val changed = sessions.filter { (it.folderId == GroupNamePolicy.SYSTEM_ID) != archive }
        changed.forEach { repo.dao.setSessionFolder(it.id, if (archive) GroupNamePolicy.SYSTEM_ID else null) }
        return JSONObject().put("archived", archive).put("changed", JSONArray(changed.map { it.id })).put("unchanged", ids.size - changed.size)
    }

    private suspend fun groups(repo: ChatRepository, args: OffloadArgs): JSONObject {
        val action = args.positional.getOrNull(1) ?: "list"
        if (action == "list") {
            val groups = repo.dao.listFolders().map { JSONObject().put("group_id", it.id).put("name", it.name)
                .put("pinned", it.isPinned).put("created_at_ms", it.createdAt).put("updated_at_ms", it.updatedAt) }
            return JSONObject().put("groups", JSONArray(groups)).put("count", groups.size)
        }
        if (action == "create") {
            val name = requireNotNull(args.get("name")) { "--name is required" } // nanoMuse: 校验前不裁掉控制字符。
            val created = repo.createFolder(name)
            return JSONObject().put("group_id", created.id).put("name", created.name)
        }
        val group = requireNotNull(repo.dao.getFolder(required(args, "id"))) { "Group not found" }
        return when (action) {
            "rename" -> { repo.renameFolder(group.id, requireNotNull(args.get("name")) { "--name is required" }); JSONObject().put("group_id", group.id) } // nanoMuse
            "delete" -> JSONObject().put("group_id", group.id).put("ungrouped_sessions", JSONArray(repo.dissolveFolder(group.id)))
            else -> throw IllegalArgumentException("Valid groups commands: list, create, rename, delete")
        }
    }

    private fun required(args: OffloadArgs, key: String): String = requireNotNull(args.get(key)?.trim()?.takeIf { it.isNotEmpty() }) { "--$key is required" }
}
