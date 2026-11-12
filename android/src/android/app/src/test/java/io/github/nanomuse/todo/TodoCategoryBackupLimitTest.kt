package io.github.nanomuse.todo

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Test

/** 分类目录也受备份容量边界约束，不能绕过总集合限制。 */
class TodoCategoryBackupLimitTest {
    @Test fun should_rejectOversizedCategoryDirectory_when_importingBackup() {
        val document = JSONObject().put("tasks", JSONArray())
            .put("categories", JSONArray(List(10_001) { "group-$it" }))
        assertTrue(runCatching { TodoBackupLimits.validateDocument(document) }.isFailure)
    }
}
