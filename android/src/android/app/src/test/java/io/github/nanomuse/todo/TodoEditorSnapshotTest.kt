package io.github.nanomuse.todo

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** 编辑恢复必须保存原修订号和提交内容，避免绕过冲突校验或误用旧操作ID。 */
class TodoEditorSnapshotTest {
    @Test
    fun should_restoreOriginalRevisionAndAllFields_when_editingExistingTask() {
        val original = TodoTask(
            ownerKey = OWNER, id = "task", title = "整理资料", notes = "第一行\n第二行",
            status = "done", scheduledDay = 20000, dueDay = 20002,
            groupName = "研究", tagsJson = "[\"资料\", \"阅读\"]",
            isImportant = true, isUrgent = true, revision = 7,
            createdAt = 100, updatedAt = 200, deletedAt = 300,
            completedDay = 20001, completedAt = 250, completionTagsJson = "[ \"旧标签\" ]",
        )

        val restored = TodoEditorSnapshot.restore(TodoEditorSnapshot.save(original), OWNER)

        assertEquals(original, restored)
        assertNotEquals(original.copy(revision = 8), restored)
    }

    @Test
    fun should_keepNewTaskIdentityAndNullDates_when_restoringUnsavedTask() {
        val original = TodoTask(ownerKey = OWNER, title = "还没有保存的任务")

        val restored = TodoEditorSnapshot.restore(TodoEditorSnapshot.save(original), OWNER)

        assertEquals(original, restored)
        assertEquals("", restored?.id)
        assertEquals(0L, restored?.revision)
        assertNull(restored?.dueDay)
    }

    @Test
    fun should_preserveExactRetryPayload_when_restoringSubmittedSnapshot() {
        val original = TodoTask(ownerKey = OWNER, id = "task", title = "原始标题", revision = 3)
        val attempted = original.copy(title = "提交标题", notes = "保留此次提交", tagsJson = "[\"学习\"]")
        val restoredOriginal = TodoEditorSnapshot.restore(TodoEditorSnapshot.save(original), OWNER)!!
        val restoredAttempt = TodoEditorSnapshot.restore(TodoEditorSnapshot.save(attempted), OWNER)!!
        val sameRetry = restoredOriginal.copy(title = "提交标题", notes = "保留此次提交", tagsJson = "[\"学习\"]")

        assertEquals(restoredAttempt, sameRetry)
        assertEquals(TodoJson.task(attempted).toString(), TodoJson.task(sameRetry).toString())
        assertNotEquals(restoredAttempt, sameRetry.copy(notes = "新的提交内容"))
    }

    @Test
    fun should_discardSnapshot_when_accountHasChanged() {
        val saved = TodoEditorSnapshot.save(TodoTask(ownerKey = OWNER, title = "私人草稿"))

        assertNull(TodoEditorSnapshot.restore(saved, "other-account"))
    }

    @Test
    fun should_discardSnapshot_when_versionIsUnsupported() {
        val saved = JSONObject(TodoEditorSnapshot.save(TodoTask(ownerKey = OWNER))).put("version", 999)

        assertNull(TodoEditorSnapshot.restore(saved.toString(), OWNER))
    }

    @Test
    fun should_discardSnapshot_when_savedStateIsIncomplete() {
        assertNull(TodoEditorSnapshot.restore("broken", OWNER))
        assertNull(TodoEditorSnapshot.restore("{\"version\":1}", OWNER))
    }

    private companion object {
        const val OWNER = "test-account"
    }
}
