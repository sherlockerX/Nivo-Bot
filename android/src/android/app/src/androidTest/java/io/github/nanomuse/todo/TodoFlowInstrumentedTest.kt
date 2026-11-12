package io.github.nanomuse.todo

import android.os.Bundle
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.material3.Text
import androidx.compose.material3.Surface
import com.openminis.app.ui.theme.ChatColors
import androidx.compose.runtime.getValue
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.room.withTransaction
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.openminis.app.MainActivity
import com.openminis.app.ui.theme.MinisTheme
import io.github.nanomuse.mosaic.MosaicDatabase
import io.github.nanomuse.mosaic.MosaicDraft
import io.github.nanomuse.mosaic.MosaicStore
import io.github.nanomuse.ui.mosaic.MosaicEditSource
import io.github.nanomuse.ui.mosaic.MosaicEditorScreen
import io.github.nanomuse.ui.mosaic.TodoMosaicPicker
import io.github.nanomuse.ui.todo.TodoEditDialog
import io.github.nanomuse.ui.todo.TodoHeader
import io.github.nanomuse.ui.todo.TodoTab
import io.github.nanomuse.ui.todo.TodoUi
import io.github.nanomuse.ui.todo.TodoView
import java.time.LocalDate
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** 原生无障碍树驱动真实Compose，不增加测试库，不读取照片或真实账号。 */
@RunWith(AndroidJUnit4::class)
class TodoFlowInstrumentedTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext
    private val today = LocalDate.now().toEpochDay()
    private val prefix = "todo-ui-${UUID.randomUUID()}"
    private val taskIds = mutableSetOf<String>()
    private val draftIds = mutableSetOf<String>()
    private val entryIds = mutableSetOf<String>()
    private lateinit var store: TodoStore

    @Before fun prepare() {
        check(context.packageName.endsWith(".uitest")) { "界面测试只能在隔离.uitest应用执行" }
        store = TodoStore.get(context)
        // 冷启动中断可能留下本用例的合成展示数据，仅按专用备注识别并清理。
        runBlocking {
            taskIds += store.tasks().filter { it.notes == "这是界面验收的合成任务，不包含真实学习记录。" }.map { it.id }
        }
        if (taskIds.isNotEmpty()) { cleanFixtures(); taskIds.clear() }
        TodoUi.view.value = TodoView.LIST
        TodoUi.backupAction.value = null
    }

    @After fun cleanFixtures() = runBlocking {
        val database = MosaicDatabase.get(context)
        val tasks = database.todoDao().allTasks(store.ownerKey).filter { it.title.startsWith(prefix) || it.id in taskIds }
        val ids = tasks.map { it.id }.toSet()
        val operations = database.todoDao().operations(store.ownerKey).filter {
            runCatching { TodoJson.readTask(org.json.JSONObject(it.resultJson)).id in ids }.getOrDefault(false)
        }
        database.withTransaction {
            val sql = database.openHelper.writableDatabase
            ids.forEach { id ->
                listOf("todo_entry_links", "todo_draft_links", "todo_events").forEach { table ->
                    sql.execSQL("DELETE FROM $table WHERE ownerKey = ? AND taskId = ?", arrayOf(store.ownerKey, id))
                }
                sql.execSQL("DELETE FROM todo_tasks WHERE ownerKey = ? AND id = ?", arrayOf(store.ownerKey, id))
            }
            operations.forEach { operation ->
                sql.execSQL("DELETE FROM todo_operations WHERE ownerKey = ? AND operationId = ?", arrayOf(store.ownerKey, operation.operationId))
            }
            sql.execSQL("DELETE FROM todo_categories WHERE ownerKey = ? AND name LIKE ?", arrayOf(store.ownerKey, "$prefix%"))
            draftIds.forEach { id -> database.dao().deleteDraft(id) }
            entryIds.forEach { id -> sql.execSQL("DELETE FROM entries WHERE id = ?", arrayOf(id)) }
        }
        TodoUi.view.value = TodoView.LIST
        TodoUi.backupAction.value = null
    }

    @Test fun should_createEditAndOpenEveryView_throughVisibleControls() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { activity -> activity.setContent {
                MinisTheme(darkTheme = false) { TodoTab(header = { TodoHeader {} }) }
            } }
            waitFor { nodes().count { it.isEditable } >= 2 }
            setText(nodes().filter { it.isEditable }.last(), "$prefix-create")
            // 原生消息队列空闲不代表Compose已经提交下一帧，等待按钮真实启用。
            waitFor { clickableNode(findText(label("nm_todo_add")))?.isEnabled == true }
            clickText(label("nm_todo_add"))
            waitFor { runBlocking { store.tasks().any { it.title == "$prefix-create" } } }
            val created = runBlocking { store.tasks().single { it.title == "$prefix-create" } }
            taskIds += created.id
            waitFor { nodes().filter { it.isEditable }.all { it.text.isNullOrBlank() } }
            clickText(created.title, allowScroll = true)
            clickText(label("nm_todo_edit"))
            waitFor { findText(label("nm_todo_edit_task")) != null }
            setText(nodes().first { it.isEditable }, "$prefix-edited")
            clickText(label("nm_todo_save"))
            waitFor { runBlocking { store.task(created.id)?.title == "$prefix-edited" } }
            waitFor { findText(label("nm_todo_edit_task")) == null }
            clickText(label("nm_todo_close"))
            waitForText(label("nm_todo_search"))
            screenshot("todo-list-light")
            listOf(TodoView.CALENDAR, TodoView.QUADRANTS, TodoView.GROUPS, TodoView.CATEGORIES, TodoView.STATUS, TodoView.STATS).forEach { view ->
                clickText(label("nm_todo_modules"))
                clickText(context.getString(view.label))
                waitFor { TodoUi.view.value == view }
                // 状态流先更新，菜单窗口随后才关闭；在新窗口可见后验证标题。
                assertNotNull("视图标题仍需可见", waitForText(label("nm_todo_title")))
                val marker = when (view) {
                    TodoView.CALENDAR -> "nm_todo_previous"
                    TodoView.QUADRANTS -> "nm_todo_q1"
                    TodoView.GROUPS -> "nm_todo_groups"
                    TodoView.CATEGORIES -> "nm_todo_category_hint"
                    TodoView.STATUS -> "nm_todo_status"
                    TodoView.STATS -> "nm_todo_statistics"
                    TodoView.LIST -> "nm_todo_search"
                }
                assertNotNull(waitForText(label(marker), allowScroll = true))
                screenshot("todo-${view.name.lowercase()}-light")
                clickText(label("nm_todo_back_list"))
                waitFor { TodoUi.view.value == TodoView.LIST }
            }
        }
    }

    @Test fun should_showCompletedTagSharesAndOpenTasks_withDarkThemeAndLargeText() = runBlocking {
        val tagged = store.saveTask(TodoTask(ownerKey = store.ownerKey, title = "$prefix-growth",
            tagsJson = todoTagsJson(listOf("Growth", "Work"))), "$prefix-tags-create")
        val work = store.saveTask(TodoTask(ownerKey = store.ownerKey, title = "$prefix-work",
            tagsJson = todoTagsJson(listOf("Work"))), "$prefix-work-create")
        taskIds += listOf(tagged.id, work.id)
        store.changeStatus(tagged.id, "done", tagged.revision, "$prefix-tags-done", today)
        store.changeStatus(work.id, "done", work.revision, "$prefix-work-done", today)
        TodoUi.view.value = TodoView.STATS
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { activity -> activity.setContent {
                val density = LocalDensity.current.density
                CompositionLocalProvider(LocalDensity provides Density(density, 1.5f)) {
                    // 与NanoMuseHome一致提供页面Surface，避免测试宿主沿用Activity的浅色背景。
                    MinisTheme(darkTheme = true) {
                        Surface(color = ChatColors.background) { TodoTab(header = { TodoHeader {} }) }
                    }
                }
            } }
            waitForText(context.getString(com.openminis.app.R.string.nm_todo_completed_count, 2), allowScroll = true)
            waitForText("Work", allowScroll = true)
            screenshot("todo-statistics-dark-large")
            clickText("Work", allowScroll = true)
            assertNotNull(waitForText(work.title, allowScroll = true))
            clickText(work.title, allowScroll = true)
            assertNotNull(waitForText(label("nm_todo_edit")))
            clickText(label("nm_todo_close"))
        }
    }

    @Test fun should_completeFromList_andChooseDateInEditor() = runBlocking {
        val task = store.saveTask(TodoTask(ownerKey = store.ownerKey, title = "$prefix-direct"), "$prefix-direct-create")
        taskIds += task.id
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { activity -> activity.setContent {
                MinisTheme(darkTheme = false) { Surface(color = ChatColors.background) { TodoTab(header = { TodoHeader {} }) } }
            } }
            clickText(label("nm_todo_confirm_done") + ": " + task.title, allowScroll = true)
            waitFor { runBlocking { store.task(task.id)?.status == "done" } }
            assertEquals(today, store.task(task.id)?.completedDay)
            // 数据库提交早于Compose下一帧，等待忙碌图标恢复；此处滚动会把目标移出视口。
            val reopenLabel = label("nm_todo_not_started") + ": " + task.title
            waitFor { clickableNode(findText(reopenLabel))?.isEnabled == true }
            clickText(reopenLabel)
            waitFor { runBlocking { store.task(task.id)?.status == "todo" } }
            setText(nodes().filter { it.isEditable }.last(), "$prefix-unsaved-draft")
            clickText(task.title)
            clickText(label("nm_todo_edit"))
            clickText(label("nm_todo_scheduled"), allowScroll = true)
            // Material日期按钮把完整日期放在text而非contentDescription；明确选择一个非今天的日期。
            val selectedDay = LocalDate.now().withDayOfMonth(if (LocalDate.now().dayOfMonth == 1) 2 else 1)
            val dayLabel = java.time.format.DateTimeFormatter.ofLocalizedDate(java.time.format.FormatStyle.FULL)
                .withLocale(context.resources.configuration.locales[0]).format(selectedDay)
            clickText(dayLabel)
            waitFor { clickableNode(findText(label("nm_todo_save")))?.isEnabled == true }
            clickText(label("nm_todo_save"))
            waitForText(label("nm_todo_edit_task"))
            screenshot("todo-edit-light")
            clickText(label("nm_todo_save"))
            waitFor { runBlocking { store.task(task.id)?.scheduledDay == selectedDay.toEpochDay() } }
            waitFor { findText(label("nm_todo_edit_task")) == null }
            clickText(label("nm_todo_close"))
            waitFor { nodes().any { it.isEditable && it.text?.toString() == "$prefix-unsaved-draft" } }
        }
    }

    @Test fun should_renderAllViews_withReadableSyntheticTasks() = runBlocking {
        val fixtures = listOf(
            Triple("整理读书笔记，留下三个可以实践的观点", "个人成长", listOf("成长", "学习")),
            Triple("完成本周实验数据的整理", "研究与工作", listOf("工作")),
            Triple("拍摄一期关于学习方法的短视频", "创作计划", listOf("创作", "成长")),
            Triple("和家人一起规划周末出行", "生活", listOf("家庭")),
            Triple("完成20分钟表达力训练", "个人成长", listOf("成长")),
            Triple("准备下一次组会的汇报提纲", "研究与工作", listOf("工作", "学习")),
        )
        fixtures.forEachIndexed { index, (title, group, tags) ->
            val saved = store.saveTask(TodoTask(ownerKey = store.ownerKey, title = title, groupName = group,
                notes = "这是界面验收的合成任务，不包含真实学习记录。", tagsJson = todoTagsJson(tags),
                scheduledDay = today, dueDay = if (index == 1) today else null,
                isImportant = index % 2 == 0, isUrgent = index < 2), "$prefix-showcase-$index")
            taskIds += saved.id
            if (index >= 4) store.changeStatus(saved.id, "done", saved.revision, "$prefix-showcase-done-$index", today)
            else if (index == 1) store.changeStatus(saved.id, "in_progress", saved.revision, "$prefix-showcase-start-$index")
        }
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { activity -> activity.setContent {
                MinisTheme(darkTheme = false) { Surface(color = ChatColors.background) { TodoTab(header = { TodoHeader {} }) } }
            } }
            // 截止日排序使该任务位于首项，等数据载入即可，避免加载期间滚动越过首项。
            waitForText(fixtures[1].first)
            screenshot("showcase-list")
            clickText(fixtures[1].first)
            waitForText(label("nm_todo_edit"))
            screenshot("showcase-detail")
            clickText(label("nm_todo_edit"))
            waitForText(label("nm_todo_edit_task"))
            screenshot("showcase-editor")
            clickText(label("nm_todo_cancel"))
            clickText(label("nm_todo_close"))
            TodoView.entries.filter { it != TodoView.LIST }.forEach { view ->
                clickText(label("nm_todo_modules"))
                clickText(context.getString(view.label))
                waitFor { TodoUi.view.value == view }
                waitForText(label("nm_todo_back_list"))
                instrumentation.waitForIdleSync()
                SystemClock.sleep(350)
                screenshot("showcase-${view.name.lowercase()}")
                clickText(label("nm_todo_back_list"))
                waitForText(label("nm_todo_search"))
            }
        }
    }

    @Test fun should_selectExplicitStatusAndRefreshRevision_withoutChangingTaskInPicker() {
        val taskState = mutableStateOf(TodoTask(ownerKey = store.ownerKey, id = "picker-fixture", title = "$prefix-picker", revision = 1))
        val selected = AtomicReference<List<TodoSelection>>(emptyList())
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { activity -> activity.setContent {
                MinisTheme(darkTheme = false) {
                    var selection by remember { mutableStateOf<List<TodoSelection>>(emptyList()) }
                    TodoMosaicPicker(listOf(taskState.value), selection, emptyMap(), today, true) {
                        selection = it; selected.set(it)
                    }
                }
            } }
            clickText(label("nm_todo_choose_tasks"))
            waitFor { nodes().any { it.isCheckable } }
            clickNode(nodes().first { it.isCheckable })
            clickText(label("nm_todo_close"))
            assertNull(selected.get().single().requestedStatus)
            scenario.onActivity { taskState.value = taskState.value.copy(revision = 2) }
            clickText(label("nm_todo_link_only"))
            clickText(label("nm_todo_in_progress"))
            waitFor { selected.get().singleOrNull()?.requestedStatus == "in_progress" }
            assertEquals("重新确认状态应采用当前任务版本", 2L, selected.get().single().expectedRevision)
            // 状态先更新、菜单稍后退出；等旧菜单项消失再点击同名锚点。
            waitFor { findText(label("nm_todo_link_only")) == null &&
                nodes().count { it.text?.toString() == label("nm_todo_in_progress") } == 1 }
            clickText(label("nm_todo_in_progress"))
            clickText(label("nm_todo_done"))
            waitFor { selected.get().singleOrNull()?.requestedStatus == "done" }
            assertEquals(today, selected.get().single().completedDay)
            assertEquals("todo", taskState.value.status)
            clickText(label("nm_todo_unlink"))
            waitFor { selected.get().isEmpty() }
        }
    }

    @Test fun should_restoreDraftStatus_then_saveDiaryAndTaskTogether() = runBlocking {
        val task = store.saveTask(TodoTask(ownerKey = store.ownerKey, title = "$prefix-restored"), "$prefix-create")
        taskIds += task.id
        val draft = draft("$prefix-draft", null)
        draftIds += draft.id
        val diary = MosaicStore.get(context)
        diary.putDraftWithTasks(draft, listOf(TodoSelection(task.id, task.revision, "done", today)), store)
        val closed = AtomicBoolean(false)
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { activity -> activity.setContent {
                MinisTheme(darkTheme = false) {
                    if (closed.get()) Text("fixture-closed")
                    else MosaicEditorScreen(today, null, null, MosaicEditSource.NONE, { closed.set(true) }, draft.id)
                }
            } }
            val restored = waitForText(task.title, allowScroll = true)
            assertNotNull(restored)
            assertNotNull(findText(label("nm_todo_done")))
            screenshot("todo-fragment-selection")
            clickText(label("nm_mosaic_save_entry"), allowScroll = true)
            waitFor { closed.get() }
        }
        val entry = requireNotNull(MosaicDatabase.get(context).dao().entryByMutation(draft.mutationId))
        entryIds += entry.id
        assertEquals("done", store.task(task.id)?.status)
        assertEquals(task.id, store.entryLinks(entry.id).single().taskId)
        assertTrue(store.draftLinks(draft.id).isEmpty())
    }

    @Test fun should_keepExplicitEmptyDraftLinks_when_reopeningExistingRecord() = runBlocking {
        val task = store.saveTask(TodoTask(ownerKey = store.ownerKey, title = "$prefix-cleared"), "$prefix-clear-create")
        taskIds += task.id
        val diary = MosaicStore.get(context)
        val original = draft("$prefix-original", null)
        val entry = requireNotNull(diary.saveWithTasks(original, LocalDate.now(), listOf(TodoSelection(task.id, task.revision)), store))
        entryIds += entry.id
        val edit = original.copy(id = "entry:${entry.id}", entryId = entry.id)
        draftIds += edit.id
        diary.putDraftWithTasks(edit, emptyList(), store)
        val closed = AtomicBoolean(false)
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { activity -> activity.setContent {
                MinisTheme(darkTheme = false) { MosaicEditorScreen(today, null, entry.id, MosaicEditSource.NONE, { closed.set(true) }, edit.id) }
            } }
            waitForText(label("nm_todo_choose_tasks"), allowScroll = true)
            assertNull("空选择不能回退到原碎片链接", findText(task.title))
            clickText(label("nm_mosaic_save_entry"), allowScroll = true)
            waitFor { closed.get() }
        }
        assertTrue(store.entryLinks(entry.id).isEmpty())
        assertEquals("todo", store.task(task.id)?.status)
    }

    @Test fun should_createAndReuseCategories_throughEditor() = runBlocking {
        val groupName = "$prefix-group"
        val tagName = "$prefix-tag"
        val first = store.saveTask(TodoTask(ownerKey = store.ownerKey, title = "$prefix-first"), "$prefix-first")
        taskIds += first.id
        val second = store.saveTask(TodoTask(ownerKey = store.ownerKey, title = "$prefix-second"), "$prefix-second")
        taskIds += second.id
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            val saved = AtomicBoolean(false)
            fun showEditor(task: TodoTask) {
                saved.set(false)
                scenario.onActivity { activity -> activity.setContent {
                    MinisTheme(darkTheme = false) {
                        var isOpen by remember(task.id) { mutableStateOf(true) }
                        if (isOpen) TodoEditDialog(task, store, { isOpen = false }, { saved.set(true); isOpen = false })
                    }
                } }
                waitForText(label("nm_todo_edit_task"))
            }
            showEditor(first)
            clickText(label("nm_todo_group"), allowScroll = true)
            waitForText(label("nm_todo_category_search"))
            setText(nodes().first { it.isEditable }, groupName)
            clickText(context.getString(com.openminis.app.R.string.nm_todo_category_create, groupName))
            waitFor { runBlocking { store.categories().any { it.name == groupName } } }
            clickText(label("nm_todo_close"))
            clickText(label("nm_todo_tags"), allowScroll = true)
            waitForText(label("nm_todo_category_search"))
            setText(nodes().first { it.isEditable }, tagName)
            clickText(context.getString(com.openminis.app.R.string.nm_todo_category_create, tagName))
            waitFor { runBlocking { store.categories().any { it.name == tagName } } }
            screenshot("category-created")
            clickText(label("nm_todo_close"))
            clickText(label("nm_todo_save"))
            waitFor { saved.get() }
            assertEquals(groupName, store.task(first.id)?.groupName)
            assertEquals(listOf(tagName), store.task(first.id)?.tags())
            showEditor(second)
            clickText(label("nm_todo_group"), allowScroll = true)
            clickText(groupName, allowScroll = true)
            screenshot("category-reuse-group")
            clickText(label("nm_todo_close"))
            clickText(label("nm_todo_tags"), allowScroll = true)
            clickText(tagName, allowScroll = true)
            clickText(label("nm_todo_close"))
            clickText(label("nm_todo_save"))
            waitFor { saved.get() }
            assertEquals(groupName, store.task(second.id)?.groupName)
            assertEquals(listOf(tagName), store.task(second.id)?.tags())
        }
    }

    private fun draft(id: String, entryId: String?): MosaicDraft = MosaicDraft(id, today, null, entryId,
        "$prefix-diary", null, null, "rounded", .5f, .5f, 1f, false, null, UUID.randomUUID().toString(), 1)

    private fun label(name: String): String {
        val id = context.resources.getIdentifier(name, "string", context.packageName)
        check(id != 0) { "缺少字符串$name" }
        return context.getString(id)
    }

    /** 截图只留在隔离测试包中，测试数据由当前用例清理。 */
    private fun screenshot(name: String) {
        // 无障碍树可能比绘制早一帧更新，等待渲染落定，避免保存上一个页面。
        instrumentation.waitForIdleSync()
        SystemClock.sleep(500)

        val bitmap = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
        try {
            java.io.File(context.filesDir, "$name.png").outputStream().use {
                check(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it))
            }
        } finally { bitmap.recycle() }
    }

    private fun nodes(): List<AccessibilityNodeInfo> {
        val root = instrumentation.uiAutomation.rootInActiveWindow ?: return emptyList()
        val pending = java.util.ArrayDeque<AccessibilityNodeInfo>()
        val result = mutableListOf<AccessibilityNodeInfo>()
        pending.add(root)
        while (pending.isNotEmpty()) {
            val node = pending.removeFirst()
            result += node
            for (index in 0 until node.childCount) node.getChild(index)?.let(pending::addLast)
        }
        return result.filter { it.isVisibleToUser }
    }

    private fun findText(text: String): AccessibilityNodeInfo? = nodes().firstOrNull {
        it.text?.toString() == text || it.contentDescription?.toString() == text || it.hintText?.toString() == text
    }

    private fun waitForText(text: String, allowScroll: Boolean = false): AccessibilityNodeInfo {
        var result: AccessibilityNodeInfo? = null
        waitFor {
            result = findText(text)
            if (result == null && allowScroll) nodes().lastOrNull { it.isScrollable && !it.isEditable }
                ?.performAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)
            result != null
        }
        return checkNotNull(result) { "未找到控件$text" }
    }

    private fun clickText(text: String, allowScroll: Boolean = false) = clickNode(waitForText(text, allowScroll))

    private fun clickableNode(initial: AccessibilityNodeInfo?): AccessibilityNodeInfo? {
        var node = initial
        while (node != null && !node.isClickable) node = node.parent
        return node
    }

    private fun clickNode(initial: AccessibilityNodeInfo) {
        val node = checkNotNull(clickableNode(initial)) { "控件没有可点击父节点" }
        assertTrue("点击失败：enabled=${node.isEnabled}, text=${node.text}", node.performAction(AccessibilityNodeInfo.ACTION_CLICK))
        instrumentation.waitForIdleSync()
    }

    private fun setText(node: AccessibilityNodeInfo, value: String) {
        assertTrue(node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, value)
        }))
        instrumentation.waitForIdleSync()
    }

    private fun waitFor(predicate: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + 10_000
        do {
            instrumentation.waitForIdleSync()
            if (predicate()) return
            SystemClock.sleep(100)
        } while (SystemClock.uptimeMillis() < deadline)
        screenshot("todo-failure")
        java.io.File(context.filesDir, "todo-failure-nodes.txt").writeText(nodes().joinToString("\n") {
            "text=${it.text}; description=${it.contentDescription}; enabled=${it.isEnabled}; scrollable=${it.isScrollable}"
        })
        fail("界面或持久化结果未在10秒内出现")
    }
}
