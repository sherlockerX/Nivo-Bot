package io.github.nanomuse.focus

import android.app.Activity
import android.content.Intent
import android.graphics.Rect
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.KeyEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleCallback
import androidx.test.runner.lifecycle.Stage
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
import org.junit.Rule
import org.junit.rules.TestName
import org.junit.runner.RunWith
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** 专用包执行真实组件点击，合成记录只按本轮前缀清理。 */
@RunWith(AndroidJUnit4::class)
class FocusFlowInstrumentedTest {
    @get:Rule val testName=TestName()
    private val instrumentation=InstrumentationRegistry.getInstrumentation()
    private val context get()=instrumentation.targetContext
    private val prefix="focus-ui-${UUID.randomUUID()}"
    private lateinit var store:FocusStore
    private var hadSetupPreference=false
    private var wasSetupDone=false
    private var hasSetupPreferenceSnapshot=false
    private var hasFailureEvidence=false
    private var isLifecycleRecording=false
    private val mainHandler=Handler(Looper.getMainLooper())
    private val waitTimeoutMs=10_000L
    private var activeWaitDeadline:Long?=null
    private val lifecycleCallback=ActivityLifecycleCallback { activity,stage ->
        if(activity.packageName==context.packageName) runCatching { appendDiagnostic(activityDescription(activity,stage)) }
    }
    @Before fun prepare() {
        check(context.packageName.endsWith(".uitest"));store=FocusStore.get(context)
        val preferences=context.getSharedPreferences("nanomuse",android.content.Context.MODE_PRIVATE)
        hadSetupPreference=preferences.contains("setup.done");wasSetupDone=preferences.getBoolean("setup.done",false)
        hasSetupPreferenceSnapshot=true
        preferences.edit().putBoolean("setup.done",true).commit()
        FocusUi.view.value="timer";FocusUi.taskId.value=null
        if(android.os.Build.VERSION.SDK_INT>=33) instrumentation.uiAutomation.grantRuntimePermission(context.packageName,android.Manifest.permission.POST_NOTIFICATIONS)
        onMain {
            ActivityLifecycleMonitorRegistry.getInstance().addLifecycleCallback(lifecycleCallback)
            isLifecycleRecording=true
        }
    }
    @After fun clean()=runBlocking<Unit> {
        // JUnit仍会在Before失败后执行After，未通过隔离包校验时禁止任何清理。
        if(!context.packageName.endsWith(".uitest") || !::store.isInitialized) return@runBlocking
        try {
            clearFixtureData()
        } finally {
            try {
                if(isLifecycleRecording) onMain {
                    ActivityLifecycleMonitorRegistry.getInstance().removeLifecycleCallback(lifecycleCallback)
                    isLifecycleRecording=false
                }
            } finally {
                if(hasSetupPreferenceSnapshot) {
                    val preferences=context.getSharedPreferences("nanomuse",android.content.Context.MODE_PRIVATE).edit()
                    if(hadSetupPreference) preferences.putBoolean("setup.done",wasSetupDone) else preferences.remove("setup.done")
                    preferences.commit()
                }
            }
        }
    }
    /** 仅移除当前用例前缀对应的夹具，偏好恢复由外层finally保障。 */
    private suspend fun clearFixtureData() {
        val database=MosaicDatabase.get(context)
        val sql=database.openHelper.writableDatabase
        val ids=database.focusDao().sessions(store.ownerKey).filter { it.title.startsWith(prefix) }.map { it.id }
        ids.forEach { id ->
            val reflectionDraft=FocusReflectionDrafts.draftId(store.ownerKey,id)
            sql.execSQL("DELETE FROM todo_draft_links WHERE draftId=?",arrayOf(reflectionDraft))
            sql.execSQL("DELETE FROM drafts WHERE id=?",arrayOf(reflectionDraft))
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
        io.github.nanomuse.ui.home.HomeBus.focusReflection.value?.let(io.github.nanomuse.ui.home.HomeBus::handledFocusReflection)
    }
    /** 宽屏保留双栏聊天，记录链接独立入栈，心得保存后回到碎片且可退回原页面。 */
    @Test fun should_openWideRecordLinks_andReturnFromReflection()=runBlocking<Unit> {
        shell("wm size 1800x1800")
        appendDiagnostic("显示尺寸：${shell("wm size")};密度：${shell("wm density")}")
        try {
            val started=store.command("start","$prefix-start",title="$prefix-wide")
            val finished=store.command("finish","$prefix-finish",started.id,started.revision)
            val cold=android.content.Intent(context,MainActivity::class.java).apply {
                action=android.content.Intent.ACTION_VIEW
                data=android.net.Uri.parse("nanomuse://views/focus")
                addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            withLiveActivity(MainActivity::class.java,cold) { scenario ->
                waitFor(description="宽屏配置达到840dp×480dp断点") {
                    var isWide=false
                    scenario.onActivity { activity ->
                        val config=activity.resources.configuration
                        isWide=config.screenWidthDp>=840 && config.screenHeightDp>=480
                    }
                    isWide
                }
                recordStage("wide-launched")
                waitForText(label("nm_focus_intro"))
                assertFalse(io.github.nanomuse.ui.home.HomeShell.active)
                recordStage("wide-cold-focus")
                openView(scenario,"mosaic")
                waitForWideMosaic(scenario)
                recordStage("wide-warm-mosaic")
                openView(scenario,"goals")
                waitForText(label("nm_goals_tracking"))
                recordStage("wide-warm-goals")
                openView(scenario,"focus")
                waitForText(label("nm_focus_intro"))
                recordStage("wide-warm-focus")
                screenshot("wide-focus-link")
                scenario.onActivity { FocusImmersiveActivity.open(it,store.ownerKey,finished.id) }
                clickText(label("nm_focus_reflection"))
                waitForText(label("nm_mosaic_editor_title"))
                recordStage("wide-reflection-editor")
                waitForText(context.getString(com.openminis.app.R.string.nm_focus_select_sessions,1),true)
                screenshot("wide-focus-reflection")
                recordWideStack("wide-before-save-click")
                clickText(label("nm_mosaic_save_entry"),true)
                recordWideStack("wide-save-click-returned")
                recordWideStack("wide-before-wait-today")
                // 保存结果只观察界面，不能为关闭已退场编辑器的输入法再发一次返回键。
                waitForText(label("nm_mosaic_day_title_today"))
                scenario.onActivity { activity ->
                    val nav=checkNotNull(navigationController(activity))
                    assertEquals(io.github.nanomuse.ui.home.ROUTE_HOME_TAB,nav.currentDestination?.route)
                    assertEquals("MOSAIC",nav.currentBackStackEntry?.arguments?.getString("tab"))
                }
                recordStage("wide-reflection-saved")
                screenshot("wide-reflection-saved")
                assertNull(FocusBackdropStore(context,store.ownerKey,store.ownerEpoch).immersiveSession())
                pressKey(KeyEvent.KEYCODE_BACK,"宽屏保存确认后返回聊天")
                waitFor { findText(label("nm_mosaic_day_title_today"))==null }
                scenario.onActivity { activity ->
                    assertEquals(com.openminis.app.ui.navigation.Routes.SESSION_LIST,
                        navigationController(activity)?.currentDestination?.route)
                }
                assertFalse(io.github.nanomuse.ui.home.HomeShell.active)
                recordStage("wide-return-to-chat")
                screenshot("wide-return-to-chat")
            }
        } finally {
            shell("wm size reset")
        }
    }

    /** 使用MainActivity实际温启动Intent，不绕过深链解析与宽屏路由。 */
    private fun openView(scenario:LiveActivity<MainActivity>,view:String) {
        scenario.onActivity { activity -> activity.startActivity(android.content.Intent(activity,MainActivity::class.java).apply {
            action=android.content.Intent.ACTION_VIEW
            data=android.net.Uri.parse("nanomuse://views/$view")
            addFlags(android.content.Intent.FLAG_ACTIVITY_CLEAR_TOP or android.content.Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }) }
    }

    /** 温启动切页先核对真实导航，再早停匹配两种可见今日标题，全程共用10秒期限。 */
    private fun waitForWideMosaic(scenario:LiveActivity<MainActivity>) {
        val startedAt=SystemClock.uptimeMillis()
        val deadline=startedAt+waitTimeoutMs
        val expected=setOf(label("nm_mosaic_day_title_today_empty"),label("nm_mosaic_day_title_today"))
        waitFor(deadline,"宽屏MOSAIC导航恢复到RESUMED") {
            onMain(deadline) {
                val activity=resumedActivity(MainActivity::class.java,scenario.taskId)
                val entry=activity?.let(::navigationController)?.currentBackStackEntry
                    ?: return@onMain false
                entry.destination.route==io.github.nanomuse.ui.home.ROUTE_HOME_TAB &&
                    entry.arguments?.getString("tab")=="MOSAIC" &&
                    entry.lifecycle.currentState==androidx.lifecycle.Lifecycle.State.RESUMED
            }
        }
        val cacheStartedAt=SystemClock.uptimeMillis()
        val isCacheCleared=android.os.Build.VERSION.SDK_INT>=33 && instrumentation.uiAutomation.clearCache()
        appendDiagnostic("warm-mosaic navReadyMs=${cacheStartedAt-startedAt} cacheCleared=$isCacheCleared cacheMs=${SystemClock.uptimeMillis()-cacheStartedAt} expected=$expected")
        var nextQueryAt=0L
        var attempt=0
        waitFor(deadline,"宽屏MOSAIC精确今日标题") {
            val queryStartedAt=SystemClock.uptimeMillis()
            if(queryStartedAt<nextQueryAt || queryStartedAt>=deadline) return@waitFor false
            val search=findVisibleText(expected,deadline,includeHint=false)
            val queryEndedAt=SystemClock.uptimeMillis()
            attempt++
            appendDiagnostic("warm-mosaic query=$attempt queryMs=${queryEndedAt-queryStartedAt} elapsedMs=${queryEndedAt-startedAt} visitedNodes=${search.visitedCount} match=${search.matchedText}")
            // 查询命中后立即结束；未命中时稍后重新读取，继续观察切页变化。
            nextQueryAt=queryEndedAt+400
            search.node!=null && SystemClock.uptimeMillis()<deadline
        }
    }
    /** 手动结束后从独立窗口进入主导航，保存和Activity重建均不再次弹出心得或沉浸窗口。 */
    @Test fun should_openReflectionFromFinishedImmersive_andConsumeNavigation()=runBlocking<Unit> {
        val started=store.command("start","$prefix-start",title="$prefix-reflection")
        withLiveActivity(MainActivity::class.java) { scenario ->
            scenario.onActivity { FocusImmersiveActivity.open(it,store.ownerKey,started.id) }
            waitForText(label("nm_focus_pause"))
            clickText(label("nm_focus_finish"))
            waitForText(label("nm_focus_finish_confirm"))
            clickNode(nodes().filter { it.text?.toString()==label("nm_focus_finish") }.last())
            clickText(label("nm_focus_reflection"))
            waitForText(label("nm_mosaic_editor_title"))
            waitForText(context.getString(com.openminis.app.R.string.nm_focus_select_sessions,1),true)
            val draftId=FocusReflectionDrafts.draftId(store.ownerKey,started.id)
            assertEquals(listOf(started.id),store.draftLinks(draftId))
            assertNull(FocusBackdropStore(context,store.ownerKey,store.ownerEpoch).immersiveSession())
            assertNull(io.github.nanomuse.ui.home.HomeBus.focusReflection.value)
            screenshot("focus-reflection-linked")
            clickText(label("nm_mosaic_save_entry"),true)
            waitFor { runBlocking { io.github.nanomuse.mosaic.MosaicStore.get(context).draft(draftId)==null } }
            waitFor { findText(label("nm_mosaic_editor_title"))==null }
            scenario.recreate()
            waitForText(label("nm_tab_mosaic"))
            assertNull(io.github.nanomuse.ui.home.HomeBus.focusReflection.value)
            assertNull(FocusBackdropStore(context,store.ownerKey,store.ownerEpoch).immersiveSession())
            assertNull(findText(label("nm_focus_pause")))
            assertNull(findText(label("nm_mosaic_editor_title")))
        }
    }

    /** 专属短时夹具由真实沉浸页自然结算，结束后按钮打开正确关联的心得。 */
    @Test fun should_openLinkedReflection_whenImmersiveCountdownExpiresNaturally()=runBlocking<Unit> {
        val started=store.command("start","$prefix-natural-start",title="$prefix-natural",minutes=3)
        withLiveActivity(MainActivity::class.java) { scenario ->
            scenario.onActivity { FocusImmersiveActivity.open(it,store.ownerKey,started.id) }
            waitForText(label("nm_focus_pause"))
            val running=store.sessions().single { it.id==started.id }
            assertEquals("running",running.status)
            // 仅缩短本用例夹具的目标；保留真实设备时钟，不调用finish或refresh代替界面结算。
            val targetMs=FocusStore.elapsed(running,context)+2500L
            MosaicDatabase.get(context).focusDao().putSession(running.copy(targetMs=targetMs,revision=running.revision+1))
            waitForText(label("nm_focus_finished_hint"))
            val finished=store.sessions().single { it.id==started.id }
            assertEquals("finished",finished.status)
            assertEquals(targetMs,finished.elapsedMs)
            assertNotNull(finished.endedAt)
            assertEquals(targetMs,store.spans().filter { it.sessionId==started.id }.sumOf { it.durationMs })
            screenshot("focus-natural-finished")
            clickText(label("nm_focus_reflection"))
            waitForText(label("nm_mosaic_editor_title"))
            waitForText(context.getString(com.openminis.app.R.string.nm_focus_select_sessions,1),true)
            val draftId=FocusReflectionDrafts.draftId(store.ownerKey,started.id)
            assertEquals(listOf(started.id),store.draftLinks(draftId))
            assertNull(FocusBackdropStore(context,store.ownerKey,store.ownerEpoch).immersiveSession())
            assertNull(io.github.nanomuse.ui.home.HomeBus.focusReflection.value)
            screenshot("focus-natural-reflection-linked")
        }
    }

    /** 重新进入已结束专注时恢复编辑过的草稿，不重新勾选用户已移除的专注关联。 */
    @Test fun should_restoreReflectionTextAndDeselection_whenReopeningFinishedSession()=runBlocking<Unit> {
        val started=store.command("start","$prefix-start",title="$prefix-kept")
        val finished=store.command("finish","$prefix-finish",started.id,started.revision)
        val todo=TodoStore.get(context)
        val mosaic=io.github.nanomuse.mosaic.MosaicStore.get(context)
        val draft=FocusReflectionDrafts.open(store,todo,mosaic,finished.id)
        mosaic.putDraftWithTasks(draft.copy(text="$prefix-written"),emptyList(),todo,emptyList(),store)
        withLiveActivity(MainActivity::class.java) { scenario ->
            scenario.onActivity { FocusImmersiveActivity.open(it,store.ownerKey,finished.id) }
            clickText(label("nm_focus_reflection"))
            waitForText("$prefix-written",true)
            waitForText(context.getString(com.openminis.app.R.string.nm_focus_select_sessions,0),true)
            assertTrue(store.draftLinks(draft.id).isEmpty())
            clickText(context.getString(android.R.string.cancel))
            clickText(label("nm_mosaic_keep"))
            waitFor { findText(label("nm_mosaic_editor_title"))==null }
            assertEquals("$prefix-written",mosaic.draft(draft.id)?.text)
            assertNull(io.github.nanomuse.ui.home.HomeBus.focusReflection.value)
        }
    }
    /** 保存成功但导航动画未卸载编辑器时，不能再生成同一草稿。 */
    @Test fun should_notRecreateDraft_afterSavingFocusOnlyEntry()=runBlocking<Unit> {
        val start=store.command("start","$prefix-start",title="$prefix-diary")
        val end=store.command("finish","$prefix-finish",start.id,start.revision)
        val closed=java.util.concurrent.atomic.AtomicBoolean(false)
        val draftId="$prefix-editor"
        withLiveActivity(MainActivity::class.java) { scenario ->
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
        withLiveActivity(MainActivity::class.java) { scenario ->
            scenario.onActivity { it.setContent { MinisTheme(darkTheme=false) { FocusTab(header={FocusHeader {}}) } } }
            // 专注都挂在待办上：在选择框里就地新建待办，新建的待办直接选中并写进待办列表。
            clickText(label("nm_focus_choose_task"),true)
            waitForText(label("nm_focus_search_or_new"))
            setText(nodes().first { it.isEditable },"$prefix-reading")
            clickText(context.getString(com.openminis.app.R.string.nm_focus_add_task,"$prefix-reading"),true)
            waitFor { runBlocking { TodoStore.get(context).tasks().any { it.title=="$prefix-reading" && it.deletedAt==null } } }
            waitForText("$prefix-reading")
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
            clickText(label("nm_focus_back"),true)
            clickText(label("nm_focus_history"));waitForText("$prefix-reading");screenshot("focus-history")
        }
    }
    @Test fun should_deleteCreatedCategory_fromVisibleManager()=runBlocking<Unit> {
        val todo=TodoStore.get(context);todo.createCategory("group","$prefix-group")
        withLiveActivity(MainActivity::class.java) { scenario ->
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
    @Test fun should_renderDarkLargeText_andChooseFocusForDiary()=runBlocking<Unit> {
        val start=store.command("start","$prefix-start",title="$prefix-review")
        val end=store.command("finish","$prefix-finish",start.id,start.revision)
        var selection=emptyList<String>()
        withLiveActivity(MainActivity::class.java) { scenario ->
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
    @Test fun should_restoreImmersiveAfterScreenOffAndRecreate()=runBlocking<Unit> {
        val started=store.command("start","$prefix-start",title="$prefix-immersive",minutes=3)
        val intent=android.content.Intent(context,FocusImmersiveActivity::class.java)
            .putExtra("focus_owner",store.ownerKey).putExtra("focus_session",started.id)
        try { withLiveActivity(FocusImmersiveActivity::class.java,intent) { scenario ->
            waitForText(started.title)
            screenshot("immersive-vector")
            shell("input keyevent 223")
            waitFor(description="屏幕实际进入休眠") { !context.getSystemService(android.os.PowerManager::class.java).isInteractive }
            recordStage("screen-off")
            shell("input keyevent 224")
            waitFor(description="屏幕实际唤醒") { context.getSystemService(android.os.PowerManager::class.java).isInteractive }
            shell("wm dismiss-keyguard")
            waitFor(description="锁屏解除") { !context.getSystemService(android.app.KeyguardManager::class.java).isKeyguardLocked }
            scenario.onActivity { assertFalse(it.isFinishing) }
            recordStage("screen-awake")
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
        } } finally {
            shell("input keyevent 224")
            shell("wm dismiss-keyguard")
        }
    }

    /** 导入按钮仅打开系统选择器；本轮按用户要求不选择或读取任何图片。 */
    @Test fun should_openAndCancelBackgroundPicker_withoutImportingImages()=runBlocking<Unit> {
        val backgrounds=FocusBackdropStore(context,store.ownerKey,store.ownerEpoch)
        val before=backgrounds.list()
        withLiveActivity(MainActivity::class.java) { scenario ->
            scenario.onActivity { it.setContent { MinisTheme { FocusBackdropPicker(backgrounds,{},{}) } } }
            waitForText(label("nm_focus_import_background"))
            screenshot("background-picker-vector")
            clickText(label("nm_focus_import_background"))
            waitFor {
                val packageName=instrumentation.uiAutomation.rootInActiveWindow?.packageName?.toString()
                packageName!=null && packageName!=context.packageName
            }
            pressKey(KeyEvent.KEYCODE_BACK)
            waitForText(label("nm_focus_import_background"))
            assertEquals(before,backgrounds.list())
        }
    }

    /** 按真实实例跟踪宿主，不用会被onNewIntent改变的Intent作为生命周期身份。 */
    private inner class LiveActivity<T:Activity>(private val activityClass:Class<T>,val taskId:Int) {
        /** 只在当前实例恢复到RESUMED后执行UI操作。 */
        fun onActivity(action:(T)->Unit) {
            val activity=awaitActivity(activityClass,taskId)
            onMain { check(!activity.isDestroyed && !activity.isFinishing);action(activity) }
        }

        /** 真正调用Activity.recreate，并同时确认旧实例销毁和新实例恢复。 */
        fun recreate() {
            val previous=awaitActivity(activityClass,taskId)
            onMain { previous.recreate() }
            waitFor(description="${activityClass.simpleName}旧实例销毁且重建实例恢复") {
                onMain {
                    previous.isDestroyed && resumedActivity(activityClass,taskId)?.let { it!==previous }==true
                }
            }
            recordStage("recreated")
        }
    }

    /** 启动真实任务，断言失败时先留存现场，再关闭本任务的所有实际窗口。 */
    private inline fun <T:Activity> withLiveActivity(
        activityClass:Class<T>,intent:Intent=Intent(context,activityClass),block:(LiveActivity<T>)->Unit,
    ) {
        var currentTaskId:Int?=null
        var originalFailure:Throwable?=null
        try {
            finishActivities()
            onMain { context.startActivity(Intent(intent).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)) }
            val activity=awaitActivity(activityClass)
            currentTaskId=activity.taskId
            recordStage("launched")
            block(LiveActivity(activityClass,activity.taskId))
        } catch(failure:Throwable) {
            originalFailure=failure
            captureFailure(failure)
            throw failure
        } finally {
            try { finishActivities(currentTaskId) }
            catch(cleanupFailure:Throwable) {
                if(originalFailure!=null) originalFailure.addSuppressed(cleanupFailure)
                else { captureFailure(cleanupFailure);throw cleanupFailure }
            }
        }
    }

    /** 生命周期查询必须在主线程执行，匹配类与任务，不匹配Intent。 */
    private fun <T:Activity> resumedActivity(activityClass:Class<T>,taskId:Int?):T? =
        ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED)
            .firstOrNull { activityClass.isInstance(it) && (taskId==null || it.taskId==taskId) }
            ?.let(activityClass::cast)

    private fun <T:Activity> awaitActivity(activityClass:Class<T>,taskId:Int?=null):T {
        var result:T?=null
        waitFor(description="${activityClass.simpleName}恢复到RESUMED") {
            result=onMain { resumedActivity(activityClass,taskId) }
            result!=null
        }
        return checkNotNull(result)
    }

    /** 列举当前应用实际存在的Activity，供现场记录与隔离任务清理使用。 */
    private fun liveActivities():List<Activity> = listOf(Stage.CREATED,Stage.STARTED,Stage.RESUMED,Stage.PAUSED,Stage.STOPPED)
        .flatMap { ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(it) }
        .filter { it.packageName==context.packageName }.distinct()

    private fun finishActivities(taskId:Int?=null) {
        onMain { liveActivities().filter { taskId==null || it.taskId==taskId }.forEach { it.finish() } }
        waitFor(description="隔离任务窗口销毁") {
            onMain { liveActivities().none { taskId==null || it.taskId==taskId } }
        }
    }

    /** 等主线程处理一次任务，采用截止时间；持续绘制不需要进入全局idle。 */
    private fun <T> onMain(deadline:Long=activeWaitDeadline ?: (SystemClock.uptimeMillis()+waitTimeoutMs),action:()->T):T {
        if(Looper.myLooper()==Looper.getMainLooper()) return action()
        val completed=CountDownLatch(1)
        val result=AtomicReference<Result<T>>()
        val runnable=Runnable { result.set(runCatching(action));completed.countDown() }
        mainHandler.post(runnable)
        if(!completed.await((deadline-SystemClock.uptimeMillis()).coerceAtLeast(0),TimeUnit.MILLISECONDS)) {
            mainHandler.removeCallbacks(runnable)
            throw AssertionError("主线程未在截止时间内处理任务")
        }
        return result.get().getOrThrow()
    }

    /** Shell输出读完才继续，避免刚发送熄屏或尺寸命令便执行下一步。 */
    private fun shell(command:String):String {
        val task=FutureTask {
            android.os.ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(command))
                .bufferedReader().use { it.readText() }
        }
        Thread(task,"focus-test-shell").apply { isDaemon=true;start() }
        return try { task.get(waitTimeoutMs,TimeUnit.MILLISECONDS) }
        finally { if(!task.isDone) task.cancel(true) }
    }

    /** 使用真实按键事件关闭输入法或唤醒设备，不直接绕过页面返回逻辑。 */
    private fun pressKey(keyCode:Int,reason:String="测试显式按键") {
        recordWideStack("key-before code=$keyCode reason=$reason")
        shell("input keyevent $keyCode")
        recordWideStack("key-returned code=$keyCode reason=$reason")
    }

    private fun activityDescription(activity:Activity,stage:Stage):String {
        val config=activity.resources.configuration
        val metrics=activity.resources.displayMetrics
        val bounds=Rect().also { activity.window?.peekDecorView()?.getWindowVisibleDisplayFrame(it) }
        return "${activity.javaClass.simpleName}@${System.identityHashCode(activity)} stage=$stage task=${activity.taskId} " +
            "intent=${activity.intent} widthDp=${config.screenWidthDp} heightDp=${config.screenHeightDp} " +
            "smallestDp=${config.smallestScreenWidthDp} density=${metrics.densityDpi} pixels=${metrics.widthPixels}x${metrics.heightPixels} " +
            "visible=$bounds HomeShell=${io.github.nanomuse.ui.home.HomeShell.active} focusView=${FocusUi.view.value} " +
            "${navigationDescription(activity)} reflection=${io.github.nanomuse.ui.home.HomeBus.focusReflection.value} " +
            "requests=${io.github.nanomuse.ui.home.HomeBus.requests.replayCache}"
    }

    /** 只读诊断主导航，不通过反射修改页面或替代实际深链。 */
    private fun navigationDescription(activity:Activity):String {
        if(activity !is MainActivity) return "route=非主窗口"
        return runCatching {
            val nav=navigationController(activity)
            val stack=if(isWideDiagnostic()) nav?.currentBackStack?.value?.joinToString(" -> ") { entry ->
                "{route=${entry.destination.route};id=${entry.id};tab=${entry.arguments?.getString("tab")};lifecycle=${entry.lifecycle.currentState}}"
            } else null
            "route=${nav?.currentDestination?.route};tab=${nav?.currentBackStackEntry?.arguments?.getString("tab")};stack=$stack"
        }.getOrElse { "route诊断失败=${it.javaClass.simpleName}" }
    }

    /** 读取当前导航对象以断言真实返回目标，不调用导航方法改变测试结果。 */
    private fun navigationController(activity:MainActivity):androidx.navigation.NavHostController? {
        val field=MainActivity::class.java.getDeclaredField("navController").apply { isAccessible=true }
        return field.get(activity) as? androidx.navigation.NavHostController
    }

    /** 只在宽屏用例的操作边界读取完整导航栈，不增加其他等待轮询的开销。 */
    private fun recordWideStack(reason:String) {
        if(!isWideDiagnostic()) return
        val snapshot=onMain {
            liveActivities().filterIsInstance<MainActivity>().joinToString("\n") { navigationDescription(it) }
        }
        appendDiagnostic("导航操作=$reason\n$snapshot")
    }

    private fun isWideDiagnostic():Boolean=testName.methodName=="should_openWideRecordLinks_andReturnFromReflection"

    private fun appendDiagnostic(message:String) {
        java.io.File(context.filesDir,"${testName.methodName}-lifecycle.txt")
            .appendText("${SystemClock.uptimeMillis()} $message\n")
    }

    private fun recordStage(name:String) {
        val snapshot=onMain {
            val monitor=ActivityLifecycleMonitorRegistry.getInstance()
            liveActivities().joinToString("\n") { activityDescription(it,monitor.getLifecycleStageOf(it)) }
        }
        val isInteractive=context.getSystemService(android.os.PowerManager::class.java).isInteractive
        val isLocked=context.getSystemService(android.app.KeyguardManager::class.java).isKeyguardLocked
        appendDiagnostic("阶段=$name interactive=$isInteractive keyguardLocked=$isLocked\n$snapshot")
    }

    private fun label(name: String): String {
        val id = context.resources.getIdentifier(name, "string", context.packageName)
        check(id != 0) { "缺少字符串$name" }
        return context.getString(id)
    }

    /** 截图只留在隔离测试包中，测试数据由当前用例清理。 */
    private fun screenshot(name: String) {
        // 无障碍树可能比绘制早一帧更新，等待渲染落定，避免保存上一个页面。
        onMain { Unit }
        SystemClock.sleep(200)

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

    /** 可见文字查询只保留命中信息，以及系统窗口内已访问的教学层节点。 */
    private data class VisibleTextSearch(
        val node:AccessibilityNodeInfo?,
        val matchedText:String?,
        val visitedCount:Int,
        val systemNodes:List<AccessibilityNodeInfo>,
    )

    /** 延迟读取兄弟节点，避免目标已在前方时仍提前获取整层节点。 */
    private data class TextTraversalFrame(
        val node:AccessibilityNodeInfo,
        var nextChildIndex:Int=0,
    )

    /** 每个节点都检查当前期限，按深度优先顺序匹配可见文字并立即返回。 */
    private fun findVisibleText(
        expected:Set<String>,deadline:Long,includeHint:Boolean=true,
    ):VisibleTextSearch {
        val effectiveDeadline=minOf(deadline,activeWaitDeadline ?: deadline)
        if(SystemClock.uptimeMillis()>=effectiveDeadline) return VisibleTextSearch(null,null,0,emptyList())
        val root=instrumentation.uiAutomation.rootInActiveWindow
            ?: return VisibleTextSearch(null,null,0,emptyList())
        val systemPackages=setOf("com.android.systemui","android")
        val isSystemWindow=root.packageName?.toString() in systemPackages
        val systemNodes=mutableListOf<AccessibilityNodeInfo>()
        val pending=java.util.ArrayDeque<TextTraversalFrame>()
        var current:AccessibilityNodeInfo?=root
        var visitedCount=0
        while(current!=null && SystemClock.uptimeMillis()<effectiveDeadline) {
            val node=current
            visitedCount++
            if(node.isVisibleToUser) {
                if(isSystemWindow && node.packageName?.toString() in systemPackages) systemNodes+=node
                val match=matchingVisibleText(node,expected,includeHint)
                if(match!=null && SystemClock.uptimeMillis()<effectiveDeadline)
                    return VisibleTextSearch(node,match,visitedCount,systemNodes)
            }
            pending.addLast(TextTraversalFrame(node))
            current=nextTextSearchNode(pending,effectiveDeadline)
        }
        return VisibleTextSearch(null,null,visitedCount,systemNodes)
    }

    /** 只读取下一个子节点；调用方在远端读取返回后再次核对期限。 */
    private fun nextTextSearchNode(
        pending:java.util.ArrayDeque<TextTraversalFrame>,deadline:Long,
    ):AccessibilityNodeInfo? {
        while(pending.isNotEmpty() && SystemClock.uptimeMillis()<deadline) {
            val frame=pending.peekLast() ?: return null
            if(frame.nextChildIndex>=frame.node.childCount) {
                pending.removeLast()
                continue
            }
            val child=frame.node.getChild(frame.nextChildIndex++)
            if(child!=null) return child
        }
        return null
    }

    /** 按需读取文本属性，标题查询不读取输入框提示。 */
    private fun matchingVisibleText(
        node:AccessibilityNodeInfo,expected:Set<String>,includeHint:Boolean,
    ):String? {
        node.text?.toString()?.let { if(it in expected) return it }
        node.contentDescription?.toString()?.let { if(it in expected) return it }
        if(includeHint) node.hintText?.toString()?.let { if(it in expected) return it }
        return null
    }

    /** 纯观察使用早停查询；系统教学层仍按实际可见内容关闭，再重新读取页面。 */
    private fun waitForObservedText(text:String,deadline:Long):AccessibilityNodeInfo {
        val effectiveDeadline=minOf(deadline,activeWaitDeadline ?: deadline)
        var result:AccessibilityNodeInfo?=null
        waitFor(effectiveDeadline,"寻找控件：$text") {
            val startedAt=SystemClock.uptimeMillis()
            val search=findVisibleText(setOf(text),effectiveDeadline)
            val endedAt=SystemClock.uptimeMillis()
            appendDiagnostic("visible-text queryMs=${endedAt-startedAt} visitedNodes=${search.visitedCount} expected=$text match=${search.matchedText}")
            if(endedAt>=effectiveDeadline) return@waitFor false
            if(dismissImmersiveTeaching(search.systemNodes)) return@waitFor false
            result=search.node
            result!=null && SystemClock.uptimeMillis()<effectiveDeadline
        }
        return checkNotNull(result) { "未找到控件$text" }
    }

    private fun waitForText(text: String, allowScroll: Boolean = false): AccessibilityNodeInfo {
        val deadline=SystemClock.uptimeMillis()+waitTimeoutMs
        if(!allowScroll) return waitForObservedText(text,deadline)
        dismissKeyboard(deadline,"寻找控件：$text")
        var result: AccessibilityNodeInfo? = null
        var direction=AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
        var nextScrollAt=0L
        var beforeScroll:String?=null
        waitFor(deadline,"寻找控件：$text") {
            // 每轮只采集一次可见树，教学层、目标查找与滚动共用当前快照。
            val visible=nodes()
            if(dismissImmersiveTeaching(visible)) return@waitFor false
            result = visible.firstOrNull {
                it.text?.toString()==text || it.contentDescription?.toString()==text || it.hintText?.toString()==text
            }
            if(result==null && SystemClock.uptimeMillis()>=nextScrollAt) {
                val fingerprint=visibleFingerprint(visible)
                if(beforeScroll==fingerprint) direction=if(direction==AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)
                    AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD else AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
                val scrollable=visible.filter { it.isScrollable && !it.isEditable }.maxByOrNull {
                    val bounds=Rect();it.getBoundsInScreen(bounds);bounds.width()*bounds.height()
                }
                val moved=scrollable?.performAction(direction)==true
                beforeScroll=if(moved) fingerprint else null
                if(!moved) direction=if(direction==AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)
                    AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD else AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
                // 一次滚动后留出动画时间，期间仍检查目标，禁止100毫秒连发滚动。
                nextScrollAt=SystemClock.uptimeMillis()+650
            }
            result != null && SystemClock.uptimeMillis()>=nextScrollAt
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
        assertTrue("控件尚不可用：${node.text}",node.isEnabled)
        assertTrue("点击失败：enabled=${node.isEnabled}, text=${node.text}", node.performAction(AccessibilityNodeInfo.ACTION_CLICK))
        onMain { Unit }
    }

    private fun setText(node: AccessibilityNodeInfo, value: String) {
        assertTrue(node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, value)
        }))
        onMain { Unit }
    }

    private fun waitFor(
        deadline:Long=SystemClock.uptimeMillis()+waitTimeoutMs,description:String="界面或持久化结果",predicate:()->Boolean,
    ) {
        val previousDeadline=activeWaitDeadline
        val effectiveDeadline=minOf(deadline,previousDeadline ?: deadline)
        activeWaitDeadline=effectiveDeadline
        try {
            do {
                // 生命周期谓词自行切到主线程；数据库等待不遍历无障碍树或等待绘制。
                if (predicate()) return
                SystemClock.sleep(minOf(100,(effectiveDeadline-SystemClock.uptimeMillis()).coerceAtLeast(0)))
            } while (SystemClock.uptimeMillis() < effectiveDeadline)
            throw AssertionError("$description 未在10秒总期限内出现")
        } catch(failure:Throwable) {
            captureFailure(failure)
            throw failure
        } finally { activeWaitDeadline=previousDeadline }
    }

    /** Android首次沉浸教学层会拦住真实应用按钮，出现时先点击确认。 */
    private fun dismissImmersiveTeaching(visible:List<AccessibilityNodeInfo>):Boolean {
        val systemNodes=visible.filter { it.packageName?.toString() in setOf("com.android.systemui","android") }
        val titles=setOf("目前处于全屏模式","You’re in full screen mode","You're in full screen mode","Viewing full screen")
        if(systemNodes.none { it.text?.toString() in titles }) return false
        systemNodes.firstOrNull { it.text?.toString() in setOf("知道了","Got it","GOT IT") }?.let {
            appendDiagnostic("实际点击系统沉浸教学确认：package=${it.packageName};text=${it.text}")
            clickNode(it)
        }
        return true
    }

    private fun visibleFingerprint(visible:List<AccessibilityNodeInfo>):String=visible.joinToString("|") {
        val bounds=Rect();it.getBoundsInScreen(bounds)
        "${it.text}:${it.contentDescription}:$bounds"
    }

    /** 仅关闭当前窗口IME并验证结果，避免导航返回误触编辑器的退出确认。 */
    private fun dismissKeyboard(deadline:Long,reason:String) {
        fun isVisible():Boolean=onMain(deadline) {
            val activity=ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED)
                .firstOrNull { it.packageName==context.packageName }
            activity?.window?.decorView?.let { ViewCompat.getRootWindowInsets(it)?.isVisible(WindowInsetsCompat.Type.ime()) }==true
        }
        val isKeyboardVisible=onMain(deadline) {
            val activity=ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED)
                .firstOrNull { it.packageName==context.packageName } ?: return@onMain false
            val decorView=activity.window.decorView
            val isVisible=ViewCompat.getRootWindowInsets(decorView)?.isVisible(WindowInsetsCompat.Type.ime())==true
            // 检查与隐藏使用同一主线程窗口；即使可见状态刚变化，也只影响键盘。
            if(isVisible) WindowCompat.getInsetsController(activity.window,decorView).hide(WindowInsetsCompat.Type.ime())
            isVisible
        }
        appendDiagnostic("dismissKeyboard-ime beforeVisible=$isKeyboardVisible hideRequested=$isKeyboardVisible reason=$reason deadline=$deadline")
        recordWideStack("dismissKeyboard-check visible=$isKeyboardVisible reason=$reason deadline=$deadline")
        if(!isKeyboardVisible) return
        waitFor(deadline,"输入法关闭") { !isVisible() }
        appendDiagnostic("dismissKeyboard-ime afterVisible=false hideRequested=true reason=$reason")
        recordWideStack("dismissKeyboard-closed reason=$reason")
    }

    /** 失败现场按用例分开保存；主线程卡住时也不再等待idle。 */
    private fun captureFailure(failure:Throwable) {
        if(hasFailureEvidence) return
        hasFailureEvidence=true
        val name="${testName.methodName}-failure"
        runCatching {
            java.io.File(context.filesDir,"$name-nodes.txt").writeText(failure.stackTraceToString()+"\n"+nodes().joinToString("\n") {
                val bounds=Rect();it.getBoundsInScreen(bounds)
                "package=${it.packageName};text=${it.text};description=${it.contentDescription};enabled=${it.isEnabled};clickable=${it.isClickable};scrollable=${it.isScrollable};bounds=$bounds"
            })
        }
        runCatching {
            val bitmap=checkNotNull(instrumentation.uiAutomation.takeScreenshot())
            try { java.io.File(context.filesDir,"$name.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it) } }
            finally { bitmap.recycle() }
        }
        runCatching {
            val snapshot=onMain(SystemClock.uptimeMillis()+1000) {
                val monitor=ActivityLifecycleMonitorRegistry.getInstance()
                liveActivities().joinToString("\n") { activityDescription(it,monitor.getLifecycleStageOf(it)) }
            }
            appendDiagnostic("失败=$failure\n$snapshot")
        }
    }
}
