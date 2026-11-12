package io.github.nanomuse.focus

import android.os.Bundle
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.openminis.app.MainActivity
import com.openminis.app.ui.theme.MinisTheme
import io.github.nanomuse.ui.focus.*
import io.github.nanomuse.ui.todo.*
import io.github.nanomuse.todo.*
import io.github.nanomuse.mosaic.MosaicDatabase
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Before
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

/** 专用包执行真实组件点击，合成记录只按本轮前缀清理。 */
@RunWith(AndroidJUnit4::class)
class FocusFlowInstrumentedTest {
    private val instrumentation=InstrumentationRegistry.getInstrumentation()
    private val context get()=instrumentation.targetContext
    private val prefix="focus-ui-${UUID.randomUUID()}"
    private lateinit var store:FocusStore
    @Before fun prepare() {
        check(context.packageName.endsWith(".uitest"));store=FocusStore.get(context)
        FocusUi.view.value="timer";FocusUi.taskId.value=null
        if(android.os.Build.VERSION.SDK_INT>=33) instrumentation.uiAutomation.grantRuntimePermission(context.packageName,android.Manifest.permission.POST_NOTIFICATIONS)
    }
    @After fun clean()=runBlocking {
        val database=MosaicDatabase.get(context)
        val sql=database.openHelper.writableDatabase
        val ids=database.focusDao().sessions(store.ownerKey).filter { it.title.startsWith(prefix) }.map { it.id }
        ids.forEach { id ->
            val entryIds=sql.query("SELECT entryId FROM focus_entry_links WHERE ownerKey=? AND sessionId=?",arrayOf(store.ownerKey,id)).use { cursor ->
                buildList { while(cursor.moveToNext()) add(cursor.getString(0)) }
            }
            entryIds.forEach { entryId -> sql.execSQL("DELETE FROM entries WHERE id=?",arrayOf(entryId)) }
            sql.execSQL("DELETE FROM focus_entry_links WHERE ownerKey=? AND sessionId=?",arrayOf(store.ownerKey,id))
            sql.execSQL("DELETE FROM focus_draft_links WHERE ownerKey=? AND sessionId=?",arrayOf(store.ownerKey,id))
            sql.execSQL("DELETE FROM focus_spans WHERE ownerKey=? AND sessionId=?",arrayOf(store.ownerKey,id))
            sql.execSQL("DELETE FROM focus_sessions WHERE ownerKey=? AND id=?",arrayOf(store.ownerKey,id))
        }
        sql.execSQL("DELETE FROM focus_operations WHERE ownerKey=? AND result LIKE ?",arrayOf(store.ownerKey,"%$prefix%"))
        sql.execSQL("DELETE FROM todo_categories WHERE ownerKey=? AND name LIKE ?",arrayOf(store.ownerKey,"$prefix%"))
        sql.execSQL("DELETE FROM drafts WHERE id=?",arrayOf("$prefix-editor"))
        FocusBackdropStore(context,store.ownerKey,store.ownerEpoch).rememberImmersive(null)
        FocusAlarm.schedule(context,null);FocusUi.view.value="timer"
    }
    /** 保存成功但导航动画未卸载编辑器时，不能再生成同一草稿。 */
    @Test fun should_notRecreateDraft_afterSavingFocusOnlyEntry()=runBlocking {
        val start=store.command("start","$prefix-start",title="$prefix-diary")
        val end=store.command("finish","$prefix-finish",start.id,start.revision)
        val closed=java.util.concurrent.atomic.AtomicBoolean(false)
        val draftId="$prefix-editor"
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { it.setContent { MinisTheme {
                io.github.nanomuse.ui.mosaic.MosaicEditorScreen(
                    java.time.LocalDate.now().toEpochDay(),null,null,
                    io.github.nanomuse.ui.mosaic.MosaicEditSource.NONE,
                    onClose={closed.set(true)},draftKey=draftId)
            } } }
            clickText(context.getString(com.openminis.app.R.string.nm_focus_select_sessions,0),true)
            clickText(end.title);clickText(label("nm_todo_close"))
            clickText(label("nm_mosaic_save_entry"),true)
            waitFor { closed.get() }
            // 超过自动保存防抖时间，保持编辑器挂载来稳定复现导航退场时的竞态。
            SystemClock.sleep(1500)
            assertNull(MosaicDatabase.get(context).dao().draft(draftId))
        }
    }
    @Test fun should_startPauseResumeFinish_andShowHistory() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { it.setContent { MinisTheme(darkTheme=false) { FocusTab(header={FocusHeader {}}) } } }
            waitForText(label("nm_focus_what"))
            setText(nodes().first { it.isEditable },"$prefix-reading")
            screenshot("focus-ready")
            clickText(label("nm_focus_start"),true)
            // 首次通知权限对话允许测试点击，拒绝同样不影响计时事实。
            waitFor {
                val allow=nodes().firstOrNull { it.viewIdResourceName?.endsWith("permission_allow_button")==true }
                if(allow!=null) clickNode(allow)
                runBlocking { store.sessions().any { it.title=="$prefix-reading" && it.status=="running" } }
            }
            waitForText(label("nm_focus_pause"));screenshot("focus-running")
            clickText(label("nm_focus_pause"));waitForText(label("nm_focus_resume"));screenshot("focus-paused")
            clickText(label("nm_focus_resume"));waitForText(label("nm_focus_pause"))
            clickText(label("nm_focus_finish"))
            waitForText(label("nm_focus_finish_confirm"))
            clickNode(nodes().filter { it.text?.toString()==label("nm_focus_finish") }.last())
            waitFor { runBlocking { store.sessions().any { it.title=="$prefix-reading" && it.status=="finished" } } }
            clickText(label("nm_focus_back"))
            clickText(label("nm_focus_history"));waitForText("$prefix-reading");screenshot("focus-history")
        }
    }
    @Test fun should_deleteCreatedCategory_fromVisibleManager()=runBlocking {
        val todo=TodoStore.get(context);todo.createCategory("group","$prefix-group")
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { it.setContent { MinisTheme { TodoCategoryPicker(todo,"group",emptyList(),{},{},isManager=true) } } }
            waitForText(label("nm_todo_groups"))
            setText(nodes().first { it.isEditable },"$prefix-group")
            waitForText("$prefix-group")
            clickText(label("nm_category_delete"));waitForText(context.getString(com.openminis.app.R.string.nm_category_delete_group_hint,"$prefix-group"))
            screenshot("category-delete-confirm")
            val actions=nodes().filter { it.text?.toString()==label("nm_category_delete") }.mapNotNull { clickableNode(it) }
            clickNode(actions.last())
            waitFor { runBlocking { todo.categories().none { it.name=="$prefix-group" } } }
        }
    }
    @Test fun should_renderDarkLargeText_andChooseFocusForDiary()=runBlocking {
        val start=store.command("start","$prefix-start",title="$prefix-review")
        val end=store.command("finish","$prefix-finish",start.id,start.revision)
        var selection=emptyList<String>()
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { it.setContent { MinisTheme(darkTheme=true) {
                CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density,1.5f)) {
                    FocusTab(header={FocusHeader {}})
                }
            } } }
            waitForText(label("nm_focus_intro"));screenshot("focus-dark-large")
            scenario.onActivity { it.setContent { MinisTheme { Column {
                FocusMosaicPicker(listOf(end),selection,emptyList(),java.time.LocalDate.now().toEpochDay(),true) { selection=it }
            } } } }
            clickText(context.getString(com.openminis.app.R.string.nm_focus_select_sessions,0))
            waitForText(end.title);clickText(end.title);waitFor { end.id in selection };screenshot("focus-diary-picker")
        }
    }
    /** 锁屏返回和Activity重建均保留同一计时，不凭视图重新开始。 */
    @Test fun should_restoreImmersiveAfterScreenOffAndRecreate()=runBlocking {
        val started=store.command("start","$prefix-start",title="$prefix-immersive",minutes=3)
        val intent=android.content.Intent(context,FocusImmersiveActivity::class.java)
            .putExtra("focus_owner",store.ownerKey).putExtra("focus_session",started.id)
        ActivityScenario.launch<FocusImmersiveActivity>(intent).use { scenario ->
            waitForText(started.title)
            screenshot("immersive-vector")
            instrumentation.uiAutomation.executeShellCommand("input keyevent 223").close()
            SystemClock.sleep(700)
            instrumentation.uiAutomation.executeShellCommand("input keyevent 224").close()
            instrumentation.uiAutomation.executeShellCommand("wm dismiss-keyguard").close()
            waitForText(label("nm_focus_pause"))
            assertEquals(started.id,store.sessions().single { it.title==started.title }.id)
            assertEquals("running",store.sessions().single { it.id==started.id }.status)
            clickText(label("nm_focus_pause"));waitForText(label("nm_focus_resume"))
            val paused=store.sessions().single { it.id==started.id }
            assertTrue(paused.elapsedMs<180000)
            scenario.recreate()
            waitForText(label("nm_focus_resume"))
            assertEquals(paused.elapsedMs,store.sessions().single { it.id==started.id }.elapsedMs)
            screenshot("immersive-restored-paused")
        }
    }

    /** 导入按钮仅打开系统选择器；本轮按用户要求不选择或读取任何图片。 */
    @Test fun should_openAndCancelBackgroundPicker_withoutImportingImages()=runBlocking {
        val backgrounds=FocusBackdropStore(context,store.ownerKey,store.ownerEpoch)
        val before=backgrounds.list()
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { it.setContent { MinisTheme { FocusBackdropPicker(backgrounds,{},{}) } } }
            waitForText(label("nm_focus_import_background"))
            screenshot("background-picker-vector")
            clickText(label("nm_focus_import_background"))
            waitFor {
                val packageName=instrumentation.uiAutomation.rootInActiveWindow?.packageName?.toString()
                packageName!=null && packageName!=context.packageName
            }
            instrumentation.uiAutomation.executeShellCommand("input keyevent 4").close()
            waitForText(label("nm_focus_import_background"))
            assertEquals(before,backgrounds.list())
        }
    }

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
            // Android首次进入沉浸模式会显示系统教学层，先确认后才能操作应用。
            val visible=nodes()
            if(visible.any { it.text?.toString() in setOf("目前处于全屏模式", "You’re in full screen mode", "You're in full screen mode") }) {
                visible.firstOrNull { it.text?.toString() in setOf("知道了", "Got it", "GOT IT") }?.let(::clickNode)
            }
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
