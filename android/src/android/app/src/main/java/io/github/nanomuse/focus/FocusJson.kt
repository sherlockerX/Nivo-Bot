package io.github.nanomuse.focus

import org.json.JSONObject

/** 工具及幂等日志共用结果编码，时间戳只由设备写入。 */
object FocusJson {
    fun session(row: FocusSession): JSONObject = JSONObject().put("id",row.id).put("title",row.title)
        .put("taskId",row.taskId ?: JSONObject.NULL).put("groupName",row.groupName).put("tags",org.json.JSONArray(row.tagsJson))
        .put("mode",row.mode).put("targetMs",row.targetMs).put("status",row.status).put("elapsedMs",row.elapsedMs)
        .put("startedAt",row.startedAt).put("endedAt",row.endedAt ?: JSONObject.NULL).put("revision",row.revision)
        .put("updatedAt",row.updatedAt).put("runningWall",row.runningWall).put("runningElapsed",row.runningElapsed)
        .put("bootCount",row.bootCount).put("deletedAt",row.deletedAt ?: JSONObject.NULL)
    fun read(owner: String, json: String): FocusSession {
        val j=JSONObject(json)
        return FocusSession(owner,j.getString("id"),j.getString("title"),if(j.isNull("taskId")) null else j.getString("taskId"),
            j.getString("groupName"),j.getJSONArray("tags").toString(),j.getString("mode"),j.getLong("targetMs"),j.getString("status"),
            j.getLong("elapsedMs"),j.getLong("startedAt"),if(j.isNull("endedAt")) null else j.getLong("endedAt"),j.getLong("updatedAt"),
            j.getLong("runningWall"),j.getLong("runningElapsed"),j.getInt("bootCount"),j.getLong("revision"),if(j.isNull("deletedAt")) null else j.getLong("deletedAt"))
    }
}
