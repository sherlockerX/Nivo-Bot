package io.github.nanomuse.ui.coach

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import io.github.nanomuse.coach.CoachAction
import io.github.nanomuse.coach.CoachCommand
import io.github.nanomuse.coach.CoachCommandService
import io.github.nanomuse.coach.CoachCourse
import io.github.nanomuse.coach.CoachDraft
import io.github.nanomuse.coach.CoachKind
import io.github.nanomuse.coach.CoachResult
import io.github.nanomuse.coach.CoachRequestState
import io.github.nanomuse.coach.CoachRuntime
import io.github.nanomuse.coach.CoachSession
import io.github.nanomuse.coach.CoachState
import io.github.nanomuse.coach.CoachTrack
import io.github.nanomuse.coach.CoachTeachingProtocol
import io.github.nanomuse.coach.CoachUserInput
import io.github.nanomuse.ui.home.MuseTones
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.util.UUID

/** 教练页展示课程与学习档案，训练统一进入绑定专题的现有聊天。 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun CoachPage(header: @Composable () -> Unit, bottomInset: Dp, onChat: (String) -> Unit,
    onOpenChat: () -> Unit = {},
    onOpenPractice: (String) -> Unit = {},
    isOpeningPractice: Boolean = false,
    onOpenConversation: (String, String?) -> Unit = { _, _ -> },
    viewModel: com.openminis.app.ui.chat.ChatViewModel? = null) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    CoachPageSpeech()
    val coachRequest by (viewModel?.nmCoachRequest
        ?: remember { MutableStateFlow<CoachRequestState?>(null) }).collectAsState()
    var service by remember { mutableStateOf<CoachCommandService?>(null) }
    var isPending by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val emptyState = remember { MutableStateFlow(CoachState()) }
    val state by (service?.state ?: emptyState).collectAsState()
    val view by CoachUi.view.collectAsState()
    val selectedId by CoachUi.selectedCourseId.collectAsState()
    val spaceEpoch by CoachRuntime.epoch.collectAsState()
    LaunchedEffect(context, spaceEpoch) {
        runCatching { withContext(Dispatchers.IO) { CoachRuntime.service(context.applicationContext) } }
            .onSuccess { service = it }.onFailure { error = it.message ?: context.getString(R.string.nm_coach_failed) }
    }
    val actions = PageActions(isPending, coachRequest?.isRunning == true) { action, target, text, payload, user, after ->
        val current = service
        if (current != null && !isPending) {
            isPending = true
            error = null
            scope.launch {
                try {
                    val command = CoachCommand(action, UUID.randomUUID().toString(), current.state.value.revision, target, text, payload)
                    val result = withContext(Dispatchers.IO) { current.execute(command, user) }
                    if (result.success) after(result) else error = result.message
                } catch (failure: Exception) {
                    error = failure.message ?: context.getString(R.string.nm_coach_failed)
                } finally {
                    isPending = false
                }
            }
        }
    }
    val selected = state.tracks.firstOrNull { it.course.id == selectedId } ?: state.tracks.firstOrNull()
    val visibleRequest = coachRequest?.takeIf { request ->
        state.sessions.any { it.id == request.sessionId && it.course.id == selected?.course?.id } ||
            (request.sessionId == null && view != "training")
    }
    // 内部视图切换从顶部开始；进入专题后返回则恢复当前页面位置。
    val scrollState = rememberSaveable(view, selectedId, saver = LazyListState.Saver) { LazyListState() }
    Column(Modifier.fillMaxSize().background(com.openminis.app.ui.theme.ChatColors.background), horizontalAlignment = Alignment.CenterHorizontally) {
        header()
        LazyColumn(
            state = scrollState,
            modifier = Modifier.fillMaxHeight().widthIn(max = 920.dp).fillMaxWidth().imePadding(),
            contentPadding = PaddingValues(bottom = bottomInset + 28.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            // 稳定key保留正文位置，打开练习期间同样提供加载反馈。
            if (service == null || isPending || isOpeningPractice) item(key = "progress") {
                Row(Modifier.padding(horizontal = 20.dp), verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    CircularProgressIndicator(Modifier.width(22.dp).height(22.dp), strokeWidth = 2.dp)
                    Text(stringResource(R.string.nm_coach_saving))
                }
            }
            (error ?: visibleRequest?.error)?.let { message -> item(key = "error") { Panel { Text(message, color = MaterialTheme.colorScheme.error) } } }
            if (coachRequest?.isRunning == true && visibleRequest == null) item(key = "busy") { Panel {
                Text(stringResource(R.string.nm_coach_other_request_busy))
                TextButton(onClick = onOpenChat) { Text(stringResource(R.string.nm_coach_open_main_chat)) }
            } }
            if (visibleRequest?.isRunning == true) item(key = "request") { Panel {
                if (visibleRequest.isAwaitingConfirmation) {
                    Text(stringResource(R.string.nm_coach_wait_chat_confirmation))
                    TextButton(onClick = onOpenChat) { Text(stringResource(R.string.nm_coach_open_main_chat)) }
                } else {
                    CircularProgressIndicator(); Text(stringResource(R.string.nm_coach_request_running))
                }
                TextButton(onClick = {
                    com.openminis.app.speech.VoiceOutputState.activePlayer?.stop()
                    viewModel?.nmCancelCoachRequest()
                }) { Text(stringResource(R.string.nm_coach_cancel_request)) }
            } }
            if (view !in setOf("courses", "training", "results")) {
                coachExploreItems(state, selected, isOpeningPractice, onOpenPractice)
            } else if (view == "courses") {
                item(key = "course_library") { LibraryPanel(state, selected, actions, onChat, onOpenPractice) }
            } else {
                if (view == "training") item(key = "training_intro") { TrainingPanel(state, selected, onOpenPractice) }
                val sessions = state.sessions.filter { selected == null || it.course.id == selected.course.id }.asReversed()
                if (sessions.isEmpty()) item(key = "archive_empty") { Panel {
                    SectionTitle(stringResource(if (view == "results") R.string.nm_coach_results else R.string.nm_coach_chat_records))
                    Text(stringResource(R.string.nm_coach_no_turns))
                } }
                items(sessions, key = { "archive:${it.id}" }, contentType = { "coach_archive" }) { session ->
                    SessionArchive(state, session, state.tracks.firstOrNull { it.course.id == session.course.id }, onOpenPractice, onOpenConversation)
                }
            }
        }
    }
}

/** 只在用户明确点击时构造并执行命令，成功回调才触发聊天。 */
private class PageActions(
    val isPending: Boolean,
    val isCoachBusy: Boolean,
    private val execute: (String, String, String, String, CoachUserInput?, (CoachResult) -> Unit) -> Unit,
) {
    /** 只有领域命令落盘成功才进入后续导航。 */
    fun run(action: String, target: String = "", text: String = "", payload: String = "",
        user: CoachUserInput? = null, after: (CoachResult) -> Unit = {}) = execute(action, target, text, payload, user, after)
}

@Composable
private fun Panel(content: @Composable () -> Unit) {
    Surface(Modifier.fillMaxWidth().padding(horizontal = 16.dp), shape = RoundedCornerShape(22.dp), color = MuseTones.surface, border = BorderStroke(1.dp, MuseTones.hairline.copy(alpha = .65f))) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) { content() }
    }
}

@Composable
private fun SectionTitle(text: String) = Text(text, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun LibraryPanel(state: CoachState, selected: CoachTrack?, actions: PageActions,
    onChat: (String) -> Unit, onOpenPractice: (String) -> Unit) {
    val context = LocalContext.current
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Panel {
            SectionTitle(stringResource(R.string.nm_coach_explore))
            Text(stringResource(R.string.nm_coach_explore_hint))
            TextButton(enabled = !actions.isPending && !actions.isCoachBusy, onClick = {
                actions.run("new_draft", text = context.getString(R.string.nm_coach_unsure_goal)) { result ->
                    onChat(context.getString(R.string.nm_coach_prompt_explore, result.targetId))
                }
            }, modifier = Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.nm_coach_unsure)) }
            var goal by rememberCoachInput("exploration")
            FlowRow(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                TextButton(onClick = { goal = context.getString(R.string.nm_coach_recent_event) + "：" }) { Text(stringResource(R.string.nm_coach_recent_event)) }
                TextButton(onClick = { goal = context.getString(R.string.nm_coach_known_direction) + "：" }) { Text(stringResource(R.string.nm_coach_known_direction)) }
            }
            Entry(goal, { goal = it }, stringResource(R.string.nm_coach_goal))
            Button(enabled = goal.isNotBlank() && !actions.isPending && !actions.isCoachBusy, onClick = {
                actions.run("new_draft", text = goal) { result ->
                    onChat(context.getString(R.string.nm_coach_prompt_explore, result.targetId))
                }
            }, modifier = Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.nm_coach_explore)) }
        }
        Panel {
            SectionTitle(stringResource(R.string.nm_coach_courses))
            state.tracks.forEach { track ->
                OutlinedButton(onClick = { CoachUi.selectedCourseId.value = track.course.id }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
                    Text(track.course.title + "·" + stringResource(R.string.nm_coach_unit_count, track.course.units.size))
                }
            }
        }
        selected?.let { track -> Panel {
            CourseDetail(track.course)
            if (track.course.needsCriteriaReview) {
                Text(stringResource(R.string.nm_coach_criteria_unreviewed))
                TextButton(onClick = { onChat(context.getString(R.string.nm_coach_prompt_review_course, track.course.id)) }) {
                    Text(stringResource(R.string.nm_coach_review_with_ai))
                }
            }
            // 大字号或较长译文时按钮换行，不被挤压截断。
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Button(onClick = { onOpenPractice(track.course.id) }, modifier = Modifier.heightIn(min = 48.dp)) {
                    Text(stringResource(R.string.nm_coach_chat_open_practice))
                }
                OutlinedButton(enabled = !actions.isPending, onClick = {
                    actions.run(if (track.paused) "resume_course" else "pause_course", track.course.id)
                }, modifier = Modifier.heightIn(min = 48.dp)) { Text(stringResource(if (track.paused) R.string.nm_coach_resume else R.string.nm_coach_pause)) }
            }
        } }
        state.drafts.forEach { draft -> DraftPanel(draft, actions, onChat) }
    }
}

@Composable
private fun DraftPanel(draft: CoachDraft, actions: PageActions, onChat: (String) -> Unit) {
    val context = LocalContext.current
    var text by rememberCoachInput("draft:${draft.id}:${draft.revision}", draft.text)
    Panel {
        SectionTitle(stringResource(R.string.nm_coach_proposal))
        Text(stringResource(R.string.nm_coach_revision, draft.revision.toString()))
        if (draft.status == "activated") Text(stringResource(R.string.nm_coach_selected))
        Entry(text, { text = it }, stringResource(R.string.nm_coach_goal))
        OutlinedButton(enabled = draft.status != "activated" && text != draft.text && !actions.isPending, onClick = {
            actions.run("revise_draft", draft.id, text)
        }, modifier = Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.nm_coach_edit_draft)) }
        draft.course?.let { course ->
            CourseDetail(course)
            Text(stringResource(R.string.nm_coach_source_limit))
            Button(enabled = text == draft.text && draft.status == "review" && draft.sourceStatus != "unverified" && !actions.isPending,
                onClick = { actions.run("activate", draft.id, payload = JSONObject().put("draftRevision", draft.revision).toString()) },
                modifier = Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.nm_coach_activate)) }
        }
        if (draft.status != "activated") TextButton(enabled = !actions.isPending && !actions.isCoachBusy, onClick = {
            onChat(context.getString(R.string.nm_coach_prompt_explore, draft.id))
        }, modifier = Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.nm_coach_continue_explore)) }
    }
}

@Composable
private fun CourseDetail(course: CoachCourse) {
    CoachSceneArt(course.kind, Modifier.fillMaxWidth().height(120.dp))
    SectionTitle(course.title)
    Text(coachPlaceName(course), color = MaterialTheme.colorScheme.onSurfaceVariant)
    if (course.needsCriteriaReview) Text(stringResource(R.string.nm_coach_criteria_unreviewed))
    if (course.units.isEmpty()) Text(stringResource(R.string.nm_coach_missing_course))
    var openUnitId by rememberSaveable(course.id, course.version) { mutableStateOf(course.units.firstOrNull()?.id) }
    course.units.forEach { unit ->
        HorizontalDivider(color = MuseTones.hairline)
        TextButton(onClick = { openUnitId = if (openUnitId == unit.id) null else unit.id },
            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
            Text(unit.id + "·" + unit.title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        }
        if (openUnitId == unit.id) {
            Text(unit.focus)
            if (unit.needsCriteriaReview) Text(stringResource(R.string.nm_coach_criteria_unreviewed))
            Text(unit.method, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            unit.criteria.forEach { criterion -> Text("• " + criterion.description, style = MaterialTheme.typography.bodySmall) }
        }
    }
    var showSource by rememberSaveable(course.id, course.version) { mutableStateOf(false) }
    TextButton(onClick = { showSource = !showSource }, modifier = Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.nm_coach_source)) }
    if (showSource) SelectionContainer { Text(course.source, style = MaterialTheme.typography.bodySmall) }
}

/** 区域详情只展示目标和存档，开始与继续均交给同一聊天导航。 */
@Composable
private fun TrainingPanel(
    state: CoachState,
    track: CoachTrack?,
    onOpenPractice: (String) -> Unit,
) {
    if (track == null) {
        Panel { Text(stringResource(R.string.nm_coach_empty)) }
        return
    }
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Panel {
            CoachSceneArt(track.course.kind, Modifier.fillMaxWidth().height(144.dp))
            SectionTitle(coachPlaceName(track.course))
            Text(track.course.title, style = MaterialTheme.typography.titleMedium)
            val unit = track.course.units.firstOrNull { it.id == track.currentUnitId }
            Text(unit?.title ?: stringResource(R.string.nm_coach_missing_course))
            unit?.let { Text(it.focus) }
            Text(stringResource(R.string.nm_coach_chat_archive_intro))
            if (track.course.needsCriteriaReview) {
                Text(stringResource(R.string.nm_coach_criteria_unreviewed))
                TextButton(onClick = { CoachUi.open("courses") }) {
                    Text(stringResource(R.string.nm_coach_courses))
                }
            }
            Button(onClick = { onOpenPractice(track.course.id) },
                modifier = Modifier.heightIn(min = 48.dp)) {
                Text(stringResource(R.string.nm_coach_chat_open_practice))
            }
        }
    }
}

/** 原始回合保留提示来源和情境，只有保存的消息标识才能提供跳转。 */
@Composable
private fun SessionTurns(session: CoachSession, onOpenConversation: (String, String?) -> Unit) {
    if (session.turns.isEmpty()) Text(stringResource(R.string.nm_coach_no_turns))
    session.turns.forEach { turn ->
        HorizontalDivider(color = MuseTones.hairline)
        TurnDescription(turn, session.teachingProtocol == CoachTeachingProtocol.VERSION)
        if (turn.context == "reported_real") {
            Text(stringResource(R.string.nm_coach_report_limit), style = MaterialTheme.typography.bodySmall)
        }
        SelectionContainer { Text(turn.text) }
        if (turn.role == "coach") {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(onClick = { CoachUi.readReply?.invoke(turn.text) },
                    modifier = Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.nm_coach_read)) }
                TextButton(onClick = { com.openminis.app.speech.VoiceOutputState.activePlayer?.stop() },
                    modifier = Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.nm_coach_stop)) }
            }
        }
        SourceMessageLink(session.chatSessionId, turn.originMessageId, onOpenConversation, turn.sourceInvalidated)
    }
}

/** 普通讨论与独立验证分别标注，提示信息只解释实际验证回合。 */
@Composable
private fun TurnDescription(turn: io.github.nanomuse.coach.CoachTurn, isTopicLesson: Boolean) {
    val label = if (isTopicLesson) when {
        turn.purpose in setOf("assessment", "attempt") -> R.string.nm_coach_chat_independent_check
        turn.context == "reported_real" -> R.string.nm_coach_report
        else -> R.string.nm_coach_chat_discussion
    } else legacyTurnLabel(turn.stage)
    Text(stringResource(label) + "·" + stringResource(if (turn.role == "user") R.string.nm_coach_you
        else R.string.nm_coach_coach), style = MaterialTheme.typography.labelLarge)
    if (!isTopicLesson || turn.purpose == "attempt") {
        Text(stringResource(if (turn.support == "none") R.string.nm_coach_no_hints else R.string.nm_coach_with_hints))
    }
    val dimensionLabel = when (turn.dimension) {
        "understanding" -> R.string.nm_coach_chat_understanding
        "application" -> R.string.nm_coach_chat_application
        else -> null
    }
    dimensionLabel?.let { Text(stringResource(it), style = MaterialTheme.typography.bodySmall) }
    if (turn.reviewKind == "delayed") Text(stringResource(R.string.nm_coach_chat_delayed_review))
}

/** 旧阶段沿用原有标签，不推断新版的验证类型。 */
private fun legacyTurnLabel(stage: String): Int = when (stage) {
    "first", "first_attempt", "attempt", "practice", "independent" -> R.string.nm_coach_original
    "retry", "supported" -> R.string.nm_coach_retry
    "probe", "transfer", "independent_probe" -> R.string.nm_coach_probe
    "real_report" -> R.string.nm_coach_report
    else -> R.string.nm_coach_chat_records
}

/** 引文与原始消息一同呈现，不把缺少证据的标准渲染成完成进度。 */
@Composable
private fun EvidenceSummary(session: CoachSession, onOpenConversation: (String, String?) -> Unit) {
    val criteria = session.course.units.firstOrNull { it.id == session.unitId }?.criteria.orEmpty()
    criteria.forEach { criterion ->
        HorizontalDivider(color = MuseTones.hairline)
        Text(criterion.description, fontWeight = FontWeight.Medium)
        val evidence = session.evidence.filter { it.criterionId == criterion.id }
        if (evidence.isEmpty()) Text(stringResource(R.string.nm_coach_unproven))
        evidence.forEach { item ->
            val turn = session.turns.firstOrNull { it.id == item.turnId }
            val isInvalidated = turn == null || turn.sourceInvalidated
            Text(stringResource(if (item.disputed || isInvalidated) R.string.nm_coach_disputed
                else if (item.met) R.string.nm_coach_supported else R.string.nm_coach_unproven))
            SelectionContainer { Text("“" + item.quote + "”\n" + item.reason) }
            SourceMessageLink(session.chatSessionId, turn?.originMessageId.orEmpty(), onOpenConversation, isInvalidated)
        }
    }
}

/** 旧档案没有原消息定位时明确显示边界，仍保留已保存的原文摘录。 */
@Composable
private fun SourceMessageLink(
    chatSessionId: String,
    messageId: String,
    onOpenConversation: (String, String?) -> Unit,
    isInvalidated: Boolean = false,
) {
    if (isInvalidated) {
        Text(stringResource(R.string.nm_coach_chat_source_invalidated),
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
    } else if (chatSessionId.isNotBlank() && messageId.isNotBlank()) {
        TextButton(onClick = { onOpenConversation(chatSessionId, messageId) },
            modifier = Modifier.heightIn(min = 48.dp)) {
            Text(stringResource(R.string.nm_coach_chat_view_original))
        }
    } else {
        Text(stringResource(R.string.nm_coach_chat_source_unavailable),
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** 一份档案展示原文、课程快照和证据，纠正与继续交回专题聊天。 */
@Composable
private fun SessionArchive(
    state: CoachState,
    session: CoachSession,
    track: CoachTrack?,
    onOpenPractice: (String) -> Unit,
    onOpenConversation: (String, String?) -> Unit,
) {
    Panel {
        val topic = state.topics.firstOrNull { it.id == session.topicId }
        SectionTitle(topic?.title ?: session.course.title)
        if (topic != null) Text(session.course.title, style = MaterialTheme.typography.bodySmall)
        val isCurrentCourse = track?.let { session.matchesCurrentCourse(it) } == true
        Text(stringResource(when {
            !isCurrentCourse -> R.string.nm_coach_old_criteria
            session.teachingProtocol != CoachTeachingProtocol.VERSION &&
                io.github.nanomuse.coach.CoachTrainingEngine.demonstrated(session) -> R.string.nm_coach_demonstrated
            session.status == "waiting_real" -> R.string.nm_coach_waiting_real
            session.status == "complete" -> R.string.nm_coach_completed
            session.status == "paused" -> R.string.nm_coach_paused
            else -> R.string.nm_coach_unfinished
        }))
        Text(session.course.units.firstOrNull { it.id == session.unitId }?.title ?: session.unitId)
        if (topic?.status == "active" && topic.chatSessionId.isNotBlank()) {
            Button(onClick = { onOpenConversation(topic.chatSessionId, null) },
                modifier = Modifier.heightIn(min = 48.dp)) {
                Text(stringResource(R.string.nm_coach_chat_back_to_conversation))
            }
        } else if (topic == null && track != null) {
            Button(onClick = { onOpenPractice(track.course.id) }, modifier = Modifier.heightIn(min = 48.dp)) {
                Text(stringResource(R.string.nm_coach_chat_open_practice))
            }
        }
        if (session.turns.any { it.sourceInvalidated }) {
            Text(stringResource(R.string.nm_coach_chat_source_invalidated), color = MaterialTheme.colorScheme.error)
        }
        if (session.draft.isNotBlank()) {
            Text(stringResource(R.string.nm_coach_chat_saved_draft), style = MaterialTheme.typography.labelLarge)
            SelectionContainer { Text(session.draft) }
        }
        LessonSummary(session, onOpenConversation)
        if (isCurrentCourse) TopicEvidence(state, session)
        EvidenceSummary(session, onOpenConversation)
        SavedActions(state.actions.filter { it.sessionId == session.id }, session.chatSessionId, onOpenConversation)
        var showTurns by rememberSaveable(session.id) { mutableStateOf(false) }
        TextButton(onClick = { showTurns = !showTurns }, modifier = Modifier.heightIn(min = 48.dp)) {
            Text(stringResource(if (showTurns) R.string.nm_coach_chat_hide_records else R.string.nm_coach_chat_show_records))
        }
        if (showTurns) SessionTurns(session, onOpenConversation)
    }
}

/** 摘要保留来源版本和更正；来源失效时只供历史回顾，不能作为当前判断。 */
@Composable
private fun LessonSummary(session: CoachSession, onOpenConversation: (String, String?) -> Unit) {
    val summary = session.lessonSummary
    if (summary == null) {
        if (session.summary.isNotBlank()) SelectionContainer { Text(session.summary) }
        return
    }
    SectionTitle(stringResource(R.string.nm_coach_chat_summary))
    Text(stringResource(R.string.nm_coach_chat_summary_version, summary.courseVersion,
        summary.sourceRevision.toString()), style = MaterialTheme.typography.bodySmall)
    if (summary.sourceInvalidated) {
        Text(stringResource(R.string.nm_coach_chat_summary_invalidated), color = MaterialTheme.colorScheme.error)
    }
    if (summary.text.isNotBlank()) SelectionContainer { Text(summary.text) }
    var showSources by rememberSaveable(session.id) { mutableStateOf(false) }
    if (summary.sources.isNotEmpty()) {
        TextButton(onClick = { showSources = !showSources }, modifier = Modifier.heightIn(min = 48.dp)) {
            Text(stringResource(if (showSources) R.string.nm_coach_chat_hide_sources else R.string.nm_coach_source))
        }
        if (showSources) SummarySources(R.string.nm_coach_source, summary.sources, session,
            summary.sourceInvalidated, onOpenConversation)
    }
    SummarySources(R.string.nm_coach_chat_corrections, summary.corrections, session, summary.sourceInvalidated, onOpenConversation)
    SummarySources(R.string.nm_coach_chat_hypotheses, summary.unresolvedHypotheses, session, summary.sourceInvalidated, onOpenConversation)
}

/** 引用始终核对原始回合，失效摘要不再提供看似有效的定位按钮。 */
@Composable
private fun SummarySources(
    title: Int,
    sources: List<io.github.nanomuse.coach.CoachSummarySource>,
    session: CoachSession,
    isSummaryInvalidated: Boolean,
    onOpenConversation: (String, String?) -> Unit,
) {
    if (sources.isEmpty()) return
    Text(stringResource(title), style = MaterialTheme.typography.labelLarge)
    sources.forEach { source ->
        SelectionContainer { Text(source.quote) }
        val turn = session.turns.firstOrNull { it.id == source.turnId }
        val isInvalidated = isSummaryInvalidated || turn == null || turn.sourceInvalidated
        SourceMessageLink(session.chatSessionId, source.messageId, onOpenConversation, isInvalidated)
    }
}

/** 三类证据从领域校验结果读取，课次结束不等于掌握专题。 */
@Composable
private fun TopicEvidence(state: CoachState, session: CoachSession) {
    if (session.topicId.isBlank() || session.teachingProtocol != CoachTeachingProtocol.VERSION) return
    val progress = runCatching { CoachTeachingProtocol.progress(state, session.topicId) }.getOrNull() ?: return
    val evidenceStates = listOf(
        R.string.nm_coach_chat_understanding to progress.hasUnderstanding,
        R.string.nm_coach_chat_application to progress.hasApplication,
        R.string.nm_coach_chat_delayed_review to progress.hasDelayedReview,
    )
    evidenceStates.forEach { (label, isSupported) ->
        Text(stringResource(label) + "·" + stringResource(if (isSupported) R.string.nm_coach_supported
            else R.string.nm_coach_unproven), style = MaterialTheme.typography.bodySmall)
    }
}

/** 旧标准记录只用于回看，不再参与当前课程的训练和通关入口。 */
private fun CoachSession.matchesCurrentCourse(track: CoachTrack): Boolean =
    !requiresCourseReview && course.id == track.course.id && course.version == track.course.version

/** 现实行动保留原计划与用户自述，报告来源不能冒充外部核验。 */
@Composable
private fun SavedActions(
    actions: List<CoachAction>,
    chatSessionId: String,
    onOpenConversation: (String, String?) -> Unit,
) {
    if (actions.isEmpty()) return
    SectionTitle(stringResource(R.string.nm_coach_actions))
    actions.forEach { action ->
        HorizontalDivider(color = MuseTones.hairline)
        Text(stringResource(when (action.status) {
            "deferred" -> R.string.nm_coach_deferred
            "reported" -> R.string.nm_coach_reported
            else -> R.string.nm_coach_planned
        }), style = MaterialTheme.typography.labelLarge)
        SelectionContainer { Text(action.plan) }
        action.planHistory.forEach { Text(it, style = MaterialTheme.typography.bodySmall) }
        action.reports.forEach { report ->
            SelectionContainer { Text(report.text) }
            SourceMessageLink(chatSessionId, report.originMessageId, onOpenConversation, report.sourceInvalidated)
        }
        Text(stringResource(R.string.nm_coach_report_limit), style = MaterialTheme.typography.bodySmall)
    }
}

@Composable
private fun Entry(text: String, onChange: (String) -> Unit, label: String) {
    OutlinedTextField(value = text, onValueChange = { com.openminis.app.speech.VoiceOutputState.activePlayer?.stop(); onChange(it) }, label = { Text(label) }, minLines = 2,
        modifier = Modifier.fillMaxWidth().onFocusChanged { if (it.isFocused) com.openminis.app.speech.VoiceOutputState.activePlayer?.stop() }, shape = RoundedCornerShape(14.dp))
}

private fun capabilityResource(kind: CoachKind): Int = when (kind) {
    CoachKind.JUDGMENT -> R.string.nm_coach_cap_judgment
    CoachKind.PERSPECTIVES -> R.string.nm_coach_cap_perspectives
    CoachKind.ENGLISH -> R.string.nm_coach_cap_english
    CoachKind.EXPRESSION -> R.string.nm_coach_cap_expression
    CoachKind.LEADERSHIP -> R.string.nm_coach_cap_leadership
    CoachKind.EXECUTION -> R.string.nm_coach_cap_execution
    CoachKind.CUSTOM -> R.string.nm_coach_cap_custom
}
