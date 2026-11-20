package io.github.nanomuse.ui.coach

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.height
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.outlined.PlayCircle
import androidx.compose.material.icons.outlined.RadioButtonUnchecked
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.ExpandLess
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
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
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import io.github.nanomuse.coach.CoachDay
import io.github.nanomuse.coach.CoachEvidenceRef
import io.github.nanomuse.coach.CoachLessonPlan
import io.github.nanomuse.coach.CoachOpenChoice
import io.github.nanomuse.coach.CoachPerformanceItem
import io.github.nanomuse.coach.CoachSkillProfile
import io.github.nanomuse.coach.CoachState
import io.github.nanomuse.coach.CoachToday
import io.github.nanomuse.coach.CoachTodayState
import io.github.nanomuse.coach.CoachTrack
import io.github.nanomuse.ui.home.MuseTones
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/**
 * 一项技能的档案页（技能列表点进来）：概况、今日训练、单元清单、当前表现和历次训练。
 * 单元清单逐项列出要学的内容，达成的打勾；细节点开单元才显示。
 */
internal fun LazyListScope.coachProfileItems(
    state: CoachState,
    selected: CoachTrack?,
    isOpening: Boolean,
    onOpenPractice: (String) -> Unit,
    onOpenConversation: (String, String?) -> Unit,
    onCourseAction: (action: String, courseId: String) -> Unit,
    onReviewCourse: (String) -> Unit,
) {
    if (selected == null) {
        item(key = "profile_empty") {
            Panel {
                SectionTitle(stringResource(R.string.nm_coach_profile_empty_title))
                Text(stringResource(R.string.nm_coach_profile_empty_body))
                Button(onClick = { CoachUi.open("courses") }, modifier = Modifier.heightIn(min = 48.dp)) {
                    Text(stringResource(R.string.nm_coach_profile_add_skill))
                }
            }
        }
        return
    }
    val courseId = selected.course.id
    item(key = "profile_summary:$courseId") { SkillSummary(selected, onCourseAction, onReviewCourse) }
    item(key = "profile_today:$courseId") { TodayPanel(state, selected, isOpening, onOpenPractice, onOpenConversation) }
    item(key = "profile_units:$courseId") { UnitChecklist(state, selected, onOpenConversation, onCourseAction) }
    item(key = "profile_performance:$courseId") { PerformancePanel(state, selected, onOpenConversation) }
    item(key = "profile_history:$courseId") { HistoryPanel(state, selected, onOpenPractice, onOpenConversation) }
}

/** 概况：场所、达成进度，以及暂停、恢复、审阅标准这几个低频操作。 */
@Composable
private fun SkillSummary(track: CoachTrack, onCourseAction: (String, String) -> Unit, onReviewCourse: (String) -> Unit) {
    val total = track.course.units.size
    val demonstrated = track.course.units.count { it.id in track.demonstrated }
    val needsReview = track.course.needsCriteriaReview || track.course.units.any { it.needsCriteriaReview }
    Panel {
        Text(coachPlaceName(track.course), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(stringResource(R.string.nm_coach_home_progress, demonstrated, total), style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold)
        LinearProgressIndicator(progress = { if (total == 0) 0f else demonstrated.toFloat() / total },
            modifier = Modifier.fillMaxWidth().height(6.dp), color = MaterialTheme.colorScheme.primary, trackColor = MuseTones.fill)
        if (track.paused) Text(stringResource(R.string.nm_coach_paused))
        if (needsReview) Text(stringResource(R.string.nm_coach_criteria_unreviewed), color = MaterialTheme.colorScheme.error)
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            if (needsReview) TextButton(onClick = { onReviewCourse(track.course.id) }, modifier = Modifier.heightIn(min = 48.dp)) {
                Text(stringResource(R.string.nm_coach_review_with_ai))
            }
            TextButton(onClick = { onCourseAction(if (track.paused) "resume_course" else "pause_course", track.course.id) },
                modifier = Modifier.heightIn(min = 48.dp)) {
                Text(stringResource(if (track.paused) R.string.nm_coach_resume else R.string.nm_coach_pause))
            }
        }
    }
}

/**
 * 单元清单：达成的单元打勾，当前单元有标记，点开单元再看细节。
 * 当前单元的展开内容里放下次安排的依据、本次教案用到的概念和材料。
 */
@Composable
private fun UnitChecklist(state: CoachState, track: CoachTrack, onOpenConversation: (String, String?) -> Unit,
    onCourseAction: (String, String) -> Unit) {
    val now by rememberCoachNow(state.revision)
    val next = remember(state, track.course.id, now) { CoachSkillProfile.nextStep(state, track.course.id, now) }
    val plan = state.plans.lastOrNull { it.courseId == track.course.id && it.status == "adopted" && it.unitId == track.currentUnitId }
    // 默认全部收起，先看清整张清单；点开单元再看细节。
    var openUnitId by rememberSaveable(track.course.id) { mutableStateOf<String?>(null) }
    var showPlans by rememberSaveable(track.course.id) { mutableStateOf(false) }
    Panel {
        SectionTitle(stringResource(R.string.nm_coach_skill_units))
        track.course.units.forEachIndexed { index, unit ->
            val isDone = unit.id in track.demonstrated
            val isCurrent = unit.id == track.currentUnitId
            val isOpen = openUnitId == unit.id
            if (index > 0) HorizontalDivider(color = MuseTones.hairline)
            val statusText = stringResource(when {
                isDone -> R.string.nm_coach_skill_unit_done
                isCurrent -> R.string.nm_coach_skill_unit_current
                else -> R.string.nm_coach_skill_unit_upcoming
            })
            Row(Modifier.fillMaxWidth().heightIn(min = 56.dp)
                .clickable { openUnitId = if (isOpen) null else unit.id }
                .semantics(mergeDescendants = true) { stateDescription = statusText },
                verticalAlignment = Alignment.CenterVertically) {
                Icon(when {
                    isDone -> Icons.Filled.CheckCircle
                    isCurrent -> Icons.Outlined.PlayCircle
                    else -> Icons.Outlined.RadioButtonUnchecked
                }, contentDescription = null, modifier = Modifier.size(24.dp),
                    tint = if (isDone || isCurrent) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
                Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
                    Text("${index + 1}. ${unit.title}", style = MaterialTheme.typography.bodyLarge,
                        fontWeight = if (isCurrent) FontWeight.SemiBold else null)
                    Text(statusText, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Icon(if (isOpen) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore, null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (isOpen) Column(Modifier.padding(start = 36.dp, bottom = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(unit.focus, style = MaterialTheme.typography.bodyMedium)
                if (unit.method.isNotBlank()) {
                    Text(stringResource(R.string.nm_coach_profile_method), style = MaterialTheme.typography.labelLarge)
                    Text(unit.method, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                if (unit.criteria.isNotEmpty()) {
                    Text(stringResource(R.string.nm_coach_skill_criteria), style = MaterialTheme.typography.labelLarge)
                    unit.criteria.forEach { Text("· " + it.description, style = MaterialTheme.typography.bodySmall) }
                }
                if (isCurrent) {
                    Text(stringResource(R.string.nm_coach_profile_next_time), style = MaterialTheme.typography.labelLarge)
                    Text(nextReason(next.kind), style = MaterialTheme.typography.bodySmall)
                    next.basis?.let { basis ->
                        Text(stringResource(R.string.nm_coach_profile_based_on, basis.quote.take(160)), style = MaterialTheme.typography.bodySmall)
                        SourceMessageLink(basis.chatSessionId, basis.messageId, onOpenConversation)
                    }
                    plan?.concepts?.takeIf { it.isNotEmpty() }?.let { concepts ->
                        Text(stringResource(R.string.nm_coach_profile_concepts), style = MaterialTheme.typography.labelLarge)
                        concepts.forEach { Text("· $it", style = MaterialTheme.typography.bodySmall) }
                    }
                    plan?.materials?.takeIf { it.isNotEmpty() }?.let { materials ->
                        Text(stringResource(R.string.nm_coach_profile_materials), style = MaterialTheme.typography.labelLarge)
                        materials.forEach {
                            Text("· ${it.title}  (${stringResource(originLabel(it.origin))})", style = MaterialTheme.typography.bodySmall)
                        }
                    }
                    val source = unit.source.ifBlank { track.course.source }
                    if (source.isNotBlank()) Text(stringResource(R.string.nm_coach_profile_course_source, source),
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    // 当前单元已达成且后面还有单元时，由用户决定是否进入下一单元。
                    if (isDone && index + 1 < track.course.units.size && !track.paused) {
                        OutlinedButton(onClick = { onCourseAction("advance", track.course.id) }, modifier = Modifier.heightIn(min = 48.dp)) {
                            Text(stringResource(R.string.nm_coach_advance))
                        }
                    }
                }
            }
        }
        val plans = state.plans.filter { it.courseId == track.course.id }.asReversed()
        if (plans.isNotEmpty()) {
            TextButton(onClick = { showPlans = !showPlans }, modifier = Modifier.heightIn(min = 48.dp)) {
                Text(stringResource(if (showPlans) R.string.nm_coach_profile_hide_plans else R.string.nm_coach_profile_show_plans, plans.size))
            }
        }
        if (showPlans) plans.take(20).forEach { item ->
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text("${dateLabel(item.localDate)} · ${stringResource(planStatus(item.status))}", style = MaterialTheme.typography.labelMedium)
                Text(item.task, style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

/** 今日训练：任务、推荐原因、时长和一个主按钮；隔天未完时给出两种选择。 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun TodayPanel(state: CoachState, track: CoachTrack, isOpening: Boolean, onOpenPractice: (String) -> Unit,
    onOpenConversation: (String, String?) -> Unit) {
    val courseId = track.course.id
    val zone = ZoneId.systemDefault()
    val now by rememberCoachNow(state.revision)
    val today = CoachDay.key(now, zone)
    val facts = remember(state, courseId, today) { CoachSkillProfile.today(state, courseId, today, zone) }
    val next = remember(state, courseId, now) { CoachSkillProfile.nextStep(state, courseId, now) }
    val preparing by CoachUi.preparing.collectAsState()
    val context = LocalContext.current
    // 没有今天的教案时，时长取教练设置里的默认值。
    var minutes by rememberSaveable(courseId) {
        mutableIntStateOf(facts.plan?.minutes ?: io.github.nanomuse.coach.CoachPrepSettings.read(context).defaultMinutes)
    }
    var need by rememberSaveable(courseId) { mutableStateOf(facts.plan?.need.orEmpty()) }
    var isAdjusting by rememberSaveable(courseId) { mutableStateOf(false) }
    var showResult by rememberSaveable(courseId) { mutableStateOf(false) }
    val isBlocked = track.paused || track.course.needsCriteriaReview || track.course.units.any { it.needsCriteriaReview }
    fun start(choice: CoachOpenChoice) {
        CoachUi.requestStart(CoachStartRequest(courseId, choice, minutes, need.trim()))
        onOpenPractice(courseId)
    }
    Surface(Modifier.fillMaxWidth().padding(horizontal = 16.dp), shape = RoundedCornerShape(22.dp), color = MuseTones.fill) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(stringResource(R.string.nm_coach_profile_today), style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold, modifier = Modifier.semantics { heading() })
            val plan = facts.openLesson?.planId?.takeIf { it.isNotBlank() }?.let { id -> state.plans.firstOrNull { it.id == id } }
                ?: facts.plan
            if (plan != null) PlanSummary(plan) else {
                Text(stringResource(R.string.nm_coach_profile_tentative), style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(track.course.units.firstOrNull { it.id == track.currentUnitId }?.title.orEmpty(),
                    style = MaterialTheme.typography.bodyLarge)
                Text(nextReason(next.kind), style = MaterialTheme.typography.bodySmall)
            }
            when (facts.state) {
                CoachTodayState.IN_PROGRESS -> Text(stringResource(R.string.nm_coach_profile_in_progress,
                    dateLabel(CoachDay.of(facts.openLesson!!, zone).ifBlank { today })), style = MaterialTheme.typography.bodySmall)
                CoachTodayState.EARLIER_UNFINISHED -> Text(stringResource(R.string.nm_coach_profile_earlier_unfinished,
                    dateLabel(CoachDay.of(facts.openLesson!!, zone))), style = MaterialTheme.typography.bodySmall)
                CoachTodayState.DONE -> Text(pluralLessons(facts), style = MaterialTheme.typography.bodySmall)
                CoachTodayState.NOT_STARTED -> Unit
            }
            val startsNew = facts.state == CoachTodayState.NOT_STARTED || facts.state == CoachTodayState.DONE ||
                facts.state == CoachTodayState.EARLIER_UNFINISHED
            if (preparing == courseId) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp)
                    Text(stringResource(R.string.nm_coach_profile_preparing, track.course.title), Modifier.weight(1f))
                    TextButton(onClick = { CoachUi.cancelPreparing() }, modifier = Modifier.heightIn(min = 48.dp)) {
                        Text(stringResource(android.R.string.cancel))
                    }
                }
            }
            val enabled = !isOpening && !isBlocked
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                when (facts.state) {
                    CoachTodayState.NOT_STARTED -> Button(onClick = { start(CoachOpenChoice.CONTINUE) }, enabled = enabled,
                        modifier = Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.nm_coach_profile_start_today)) }
                    CoachTodayState.IN_PROGRESS -> Button(onClick = { start(CoachOpenChoice.CONTINUE) }, enabled = enabled,
                        modifier = Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.nm_coach_profile_continue)) }
                    CoachTodayState.EARLIER_UNFINISHED -> {
                        Button(onClick = { start(CoachOpenChoice.CONTINUE) }, enabled = enabled, modifier = Modifier.heightIn(min = 48.dp)) {
                            Text(stringResource(R.string.nm_coach_profile_continue_earlier))
                        }
                        OutlinedButton(onClick = { start(CoachOpenChoice.START_TODAY) }, enabled = enabled, modifier = Modifier.heightIn(min = 48.dp)) {
                            Text(stringResource(R.string.nm_coach_profile_start_new_day))
                        }
                    }
                    CoachTodayState.DONE -> {
                        Button(onClick = { showResult = !showResult }, modifier = Modifier.heightIn(min = 48.dp)) {
                            Text(stringResource(if (showResult) R.string.nm_coach_profile_hide_result else R.string.nm_coach_profile_view_result))
                        }
                        OutlinedButton(onClick = { start(CoachOpenChoice.CONTINUE) }, enabled = enabled, modifier = Modifier.heightIn(min = 48.dp)) {
                            Text(stringResource(R.string.nm_coach_profile_practice_more))
                        }
                    }
                }
            }
            if (startsNew && !isBlocked) {
                TextButton(onClick = { isAdjusting = !isAdjusting }, modifier = Modifier.heightIn(min = 48.dp)) {
                    Text(stringResource(R.string.nm_coach_profile_adjust, minutes))
                    Icon(if (isAdjusting) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore, null)
                }
                if (isAdjusting) {
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        listOf(5, 10, 15, 25, 40).forEach { value ->
                            FilterChip(selected = minutes == value, onClick = { minutes = value },
                                label = { Text(stringResource(R.string.nm_coach_profile_minutes, value)) },
                                modifier = Modifier.semantics { this.selected = minutes == value })
                        }
                    }
                    OutlinedTextField(value = need, onValueChange = { need = it.take(600) },
                        label = { Text(stringResource(R.string.nm_coach_profile_need)) }, modifier = Modifier.fillMaxWidth())
                }
            }
        }
    }
    if (facts.state == CoachTodayState.DONE && showResult) {
        facts.lessonsToday.asReversed().forEach { lesson ->
            SessionArchive(state, lesson, track, onOpenPractice, onOpenConversation)
        }
    }
}

/** 教案摘要：页面只显示任务说明，参考解答留给旁聊。 */
@Composable
private fun PlanSummary(plan: CoachLessonPlan) {
    Text(stringResource(if (plan.source == "base") R.string.nm_coach_profile_plan_base else R.string.nm_coach_profile_plan_prepared,
        plan.minutes), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    Text(plan.task, style = MaterialTheme.typography.bodyLarge)
    Text(plan.reason.ifBlank { nextReason(plan.nextKind) }, style = MaterialTheme.typography.bodySmall)
    if (plan.source == "base" && plan.degradeReason.isNotBlank()) Text(stringResource(degradeText(plan.degradeReason)),
        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    if (plan.need.isNotBlank()) Text(stringResource(R.string.nm_coach_profile_need_used, plan.need), style = MaterialTheme.typography.bodySmall)
}

/** 当前表现：理解、应用和延迟复核各一行，点开看原话、日期、提示和情境。 */
@Composable
private fun PerformancePanel(state: CoachState, track: CoachTrack, onOpenConversation: (String, String?) -> Unit) {
    val now by rememberCoachNow(state.revision)
    val items = remember(state, track.course.id, now) { CoachSkillProfile.performance(state, track.course.id, now) }
    Panel {
        SectionTitle(stringResource(R.string.nm_coach_profile_performance))
        if (items.isEmpty()) Text(stringResource(R.string.nm_coach_profile_no_evidence))
        items.forEach { item -> PerformanceRow(item, onOpenConversation) }
    }
}

@Composable
private fun PerformanceRow(item: CoachPerformanceItem, onOpenConversation: (String, String?) -> Unit) {
    var isOpen by rememberSaveable(item.dimension, item.evidence?.turnId) { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().heightIn(min = 48.dp)
        .then(if (item.evidence != null) Modifier.clickable { isOpen = !isOpen } else Modifier),
        verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(stringResource(dimensionLabel(item.dimension)), style = MaterialTheme.typography.labelLarge)
        Text(performanceText(item), style = MaterialTheme.typography.bodyMedium)
        if (isOpen) item.evidence?.let { EvidenceDetail(it, onOpenConversation) }
    }
}

@Composable
private fun EvidenceDetail(ref: CoachEvidenceRef, onOpenConversation: (String, String?) -> Unit) {
    SelectionContainer { Text("“${ref.quote}”", style = MaterialTheme.typography.bodyMedium) }
    if (ref.reason.isNotBlank()) Text(ref.reason, style = MaterialTheme.typography.bodySmall)
    Text(stringResource(R.string.nm_coach_profile_evidence_meta, dateTimeLabel(ref.at),
        stringResource(if (ref.support == "hinted") R.string.nm_coach_with_hints else R.string.nm_coach_no_hints),
        stringResource(if (ref.context == "reported_real") R.string.nm_coach_profile_context_real else R.string.nm_coach_profile_context_simulation)),
        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    SourceMessageLink(ref.chatSessionId, ref.messageId, onOpenConversation)
}

/** 历次训练按日期分节，展开查看当天的任务、反馈、证据和未决问题。 */
@Composable
private fun HistoryPanel(state: CoachState, track: CoachTrack, onOpenPractice: (String) -> Unit,
    onOpenConversation: (String, String?) -> Unit) {
    val zone = ZoneId.systemDefault()
    val byDate = remember(state, track.course.id, zone) {
        state.sessions.filter { it.course.id == track.course.id }.groupBy { CoachDay.of(it, zone) }
            .toList().sortedByDescending { it.first }
    }
    var openDate by rememberSaveable(track.course.id) { mutableStateOf<String?>(null) }
    Panel {
        SectionTitle(stringResource(R.string.nm_coach_profile_history))
        if (byDate.isEmpty()) Text(stringResource(R.string.nm_coach_no_turns))
        byDate.take(30).forEach { (date, lessons) ->
            val isOpen = openDate == date
            Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable { openDate = if (isOpen) null else date },
                verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(if (date.isBlank()) stringResource(R.string.nm_coach_profile_undated) else dateLabel(date),
                        style = MaterialTheme.typography.titleSmall)
                    Text(stringResource(R.string.nm_coach_profile_lessons_count, lessons.size), style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Icon(if (isOpen) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore, null)
            }
        }
    }
    byDate.firstOrNull { it.first == openDate }?.second?.asReversed()?.forEach { lesson ->
        SessionArchive(state, lesson, track, onOpenPractice, onOpenConversation)
    }
}

@Composable
private fun pluralLessons(facts: CoachToday): String =
    stringResource(R.string.nm_coach_profile_done_today, facts.lessonsToday.size)

@Composable
private fun performanceText(item: CoachPerformanceItem): String = when (item.status) {
    "independent" -> stringResource(R.string.nm_coach_profile_perf_independent, dateLabel(item.evidence!!.at))
    "hinted" -> stringResource(R.string.nm_coach_profile_perf_hinted, dateLabel(item.evidence!!.at))
    "attempted" -> stringResource(R.string.nm_coach_profile_perf_attempted, dateLabel(item.evidence!!.at))
    "due" -> stringResource(R.string.nm_coach_profile_perf_review_due)
    "waiting" -> stringResource(R.string.nm_coach_profile_perf_review_waiting, dateTimeLabel(item.dueAt))
    else -> stringResource(R.string.nm_coach_profile_no_evidence)
}

private fun dimensionLabel(dimension: String): Int = when (dimension) {
    "understanding" -> R.string.nm_coach_profile_dim_understanding
    "application" -> R.string.nm_coach_profile_dim_application
    else -> R.string.nm_coach_profile_dim_delayed
}

@Composable
private fun nextReason(kind: String): String = stringResource(when (kind) {
    CoachSkillProfile.NEXT_DIAGNOSE -> R.string.nm_coach_profile_next_diagnose
    CoachSkillProfile.NEXT_NEW_SCENARIO -> R.string.nm_coach_profile_next_new_scenario
    CoachSkillProfile.NEXT_INDEPENDENT_FIRST -> R.string.nm_coach_profile_next_independent
    CoachSkillProfile.NEXT_DELAYED_REVIEW -> R.string.nm_coach_profile_next_delayed
    CoachSkillProfile.NEXT_WAIT_REVIEW -> R.string.nm_coach_profile_next_wait_review
    CoachSkillProfile.NEXT_REAL_ACTION -> R.string.nm_coach_profile_next_real_action
    CoachSkillProfile.NEXT_DISPUTED -> R.string.nm_coach_profile_next_disputed
    CoachSkillProfile.NEXT_ADVANCE -> R.string.nm_coach_profile_next_advance
    else -> R.string.nm_coach_profile_next_continue
})

internal fun degradeText(reason: String): Int = when {
    reason == "prep_off" -> R.string.nm_coach_profile_degrade_off
    reason == "no_model" -> R.string.nm_coach_profile_degrade_no_model
    reason == "timeout" || reason.startsWith("model_error") -> R.string.nm_coach_profile_degrade_model
    else -> R.string.nm_coach_profile_degrade_invalid
}

private fun planStatus(status: String): Int = when (status) {
    "adopted" -> R.string.nm_coach_profile_plan_adopted
    else -> R.string.nm_coach_profile_plan_superseded
}

private fun originLabel(origin: String): Int = when (origin) {
    "course" -> R.string.nm_coach_profile_origin_course
    "user" -> R.string.nm_coach_profile_origin_user
    "self_authored" -> R.string.nm_coach_profile_origin_self
    else -> R.string.nm_coach_profile_origin_unverified
}

private fun dateLabel(date: String): String = runCatching {
    LocalDate.parse(date).format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM))
}.getOrDefault(date)

private fun dateLabel(at: Long): String =
    Instant.ofEpochMilli(at).atZone(ZoneId.systemDefault()).toLocalDate().format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM))

private fun dateTimeLabel(at: Long): String =
    Instant.ofEpochMilli(at).atZone(ZoneId.systemDefault()).format(DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT))

/** 当前时间每30秒刷新一次：页面跨过午夜后，今日训练和延迟复核会换到新的一天。 */
@Composable
private fun rememberCoachNow(revision: Long): androidx.compose.runtime.State<Long> =
    androidx.compose.runtime.produceState(System.currentTimeMillis(), revision) {
        value = System.currentTimeMillis()
        while (true) {
            kotlinx.coroutines.delay(30_000)
            value = System.currentTimeMillis()
        }
    }
