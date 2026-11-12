package io.github.nanomuse.ui.feed

import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringArrayResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openminis.app.R
import com.openminis.app.scheduled.ScheduledTaskStore
import com.openminis.app.ui.markdown.MarkdownText
import com.openminis.app.ui.theme.ChatColors
import io.github.nanomuse.feed.FeedFlow
import io.github.nanomuse.feed.FeedPost
import io.github.nanomuse.feed.FeedStore
import io.github.nanomuse.ui.home.MuseTones
import kotlinx.coroutines.flow.MutableStateFlow
import java.text.DateFormat
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/** The header's buttons and the tab live in different composables; this is the wire. */
object FeedUi {
    val settingsOpen = MutableStateFlow(false)
    /** Mosaic: the calendar button left of the settings opens the training calendar. */
    val calendarOpen = MutableStateFlow(false)
}

/** 单一教练入口保留旧日历与设置，训练内容使用新的共享课程视图。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FeedTab(
    coachViewModel: com.openminis.app.ui.chat.ChatViewModel? = null,
    onOpenChat: () -> Unit = {},
    onOpenPractice: (String) -> Unit = {},
    isOpeningPractice: Boolean = false, // 打开练习要写档案和数据库，期间在教练页显示进度。
    onOpenConversation: (String, String?) -> Unit = { _, _ -> },
    header: @Composable () -> Unit,
    onDiscuss: (FeedPost) -> Unit,
    onEditRoutine: (String) -> Unit,
    bottomInset: Dp = 0.dp,
    // Mosaic: the training settings open a skill, the skills list and the mounted folders.
    onOpenSkill: (String) -> Unit = {},
    onOpenSkills: () -> Unit = {},
    onOpenFolders: () -> Unit = {},
    // Mosaic: a chat of its own with this first message (designing an ability's course).
    onChat: (title: String, opener: String) -> Unit = { _, _ -> },
) {
    val context = LocalContext.current
    val posts by FeedStore.posts.collectAsState()
    val settingsOpen by FeedUi.settingsOpen.collectAsState()
    val calendarOpen by FeedUi.calendarOpen.collectAsState()
    var infoPost by remember { mutableStateOf<FeedPost?>(null) }
    var calendarDay by remember { mutableStateOf<String?>(null) }

    // nanoMuse: 教练内容与主聊天共用领域服务；浏览页面不会启动模型或隐藏定时任务。
    val today = todayKey()
    io.github.nanomuse.ui.coach.CoachPage(
        header = header,
        bottomInset = bottomInset,
        onChat = { onChat("", it) },
        onOpenChat = onOpenChat,
        onOpenPractice = onOpenPractice,
        isOpeningPractice = isOpeningPractice,
        onOpenConversation = onOpenConversation,
        viewModel = coachViewModel,
    )

    if (calendarOpen) {
        CoachCalendarSheet(
            posts = posts,
            initialDay = calendarDay ?: today,
            onDismiss = { FeedUi.calendarOpen.value = false; calendarDay = null },
            onDiscuss = { FeedUi.calendarOpen.value = false; calendarDay = null; onDiscuss(it) },
            onInfo = { infoPost = it },
        )
    }

    if (settingsOpen) {
        FeedSettingsSheet(
            onDismiss = { FeedUi.settingsOpen.value = false },
            onEditRoutine = onEditRoutine,
            onOpenSkill = onOpenSkill,
            onOpenSkills = onOpenSkills,
            onOpenFolders = onOpenFolders,
        )
    }

    infoPost?.let { post ->
        val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
        ModalBottomSheet(
            onDismissRequest = { infoPost = null },
            sheetState = sheetState,
            containerColor = ChatColors.background,
        ) {
            Column(Modifier.padding(horizontal = 24.dp).padding(bottom = 28.dp)) {
                Text(post.title, fontSize = 18.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurface)
                Spacer(Modifier.height(12.dp))
                InfoRow(stringResource(R.string.nm_feed_info_type), typeLabel(post.type))
                // Mosaic: a 24-hour time, not "3:05 PM".
                InfoRow(stringResource(R.string.nm_feed_info_written), SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.ROOT).format(Date(post.createdAt)))
                if (post.source.isNotEmpty()) InfoRow(stringResource(R.string.nm_feed_info_source), post.source.joinToString("\n"))
                InfoRow(stringResource(R.string.nm_feed_info_file), "minis-global/nanomuse/feed/${post.day}/${"%02d".format(Locale.ROOT, post.index)}.md")
                Spacer(Modifier.height(16.dp))
                TextButton(onClick = { FeedStore.delete(post); infoPost = null }) {
                    Icon(Icons.Outlined.DeleteOutline, contentDescription = null, tint = MaterialTheme.colorScheme.error, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(stringResource(R.string.nm_feed_delete), color = MaterialTheme.colorScheme.error)
                }
            }
        }
    }
}

@Composable
private fun InfoRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.Top) {
        Text(label, fontSize = 13.sp, color = ChatColors.secondaryText, modifier = Modifier.width(72.dp))
        Text(value, fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurface)
    }
}

@Composable
internal fun DayTitle(text: String) {
    Text(
        text = text,
        fontSize = 22.sp,
        lineHeight = 28.sp,
        fontWeight = FontWeight.Bold,
        color = MaterialTheme.colorScheme.onSurface,
        modifier = Modifier.padding(start = 20.dp, end = 20.dp, top = 14.dp, bottom = 8.dp),
    )
}

/** White card frame shared by every card on the page. */
@Composable
private fun FeedCard(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Surface(
        shape = RoundedCornerShape(18.dp),
        color = MuseTones.surface,
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 14.dp, vertical = 6.dp)
            .animateContentSize(),
    ) { content() }
}

@Composable
internal fun PostCard(
    post: FeedPost,
    onDiscuss: () -> Unit,
    onInfo: () -> Unit,
    modifier: Modifier = Modifier,
) {
    FeedCard(modifier) {
        Column(Modifier.padding(start = 14.dp, end = 10.dp, top = 14.dp, bottom = 6.dp)) {
            Row(verticalAlignment = Alignment.Top) {
                Box(
                    modifier = Modifier
                        .size(44.dp)
                        .background(MuseTones.fill, RoundedCornerShape(12.dp)),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(post.emoji.ifBlank { defaultEmoji(post.type) }, fontSize = 22.sp)
                }
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    GrowthTag(post) // Mosaic
                    Text(
                        post.title,
                        fontSize = 16.sp,
                        lineHeight = 22.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    Spacer(Modifier.height(4.dp))
                    MarkdownText(
                        markdown = post.body,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.86f),
                        style = MaterialTheme.typography.bodyMedium.copy(fontSize = 15.sp, lineHeight = 22.sp),
                    )
                }
            }
            GrowthAnswer(post) // Mosaic: the question, the answer and its review
            Spacer(Modifier.height(6.dp))
            // Mosaic: no heart; a training card is answered, not liked.
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                FooterAction(
                    icon = Icons.Outlined.ChatBubbleOutline,
                    tint = MaterialTheme.colorScheme.onSurface,
                    label = stringResource(R.string.nm_feed_discuss),
                    contentDescription = null,
                    onClick = onDiscuss,
                )
                Spacer(Modifier.weight(1f))
                FooterAction(
                    icon = Icons.Outlined.Info,
                    tint = MaterialTheme.colorScheme.onSurface,
                    label = null,
                    contentDescription = stringResource(R.string.nm_a11y_post_details),
                    onClick = onInfo,
                )
            }
        }
    }
}

/**
 * One action under a post. [label] is the visible text, if any; [contentDescription] is the
 * name a screen reader gets for an icon-only action (null when the label already names it);
 * [stateDescription] is read after the name for a toggle such as Like.
 */
@Composable
private fun FooterAction(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    tint: Color,
    label: String?,
    contentDescription: String?,
    onClick: () -> Unit,
    stateDescription: String? = null,
    iconModifier: Modifier = Modifier,
) {
    Row(
        modifier = Modifier
            .then(if (stateDescription != null) Modifier.semantics { this.stateDescription = stateDescription } else Modifier)
            .clickable(onClick = onClick)
            .padding(horizontal = 8.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = contentDescription, tint = tint, modifier = iconModifier.size(22.dp))
        if (label != null) {
            Spacer(Modifier.width(6.dp))
            Text(label, fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurface)
        }
    }
}

/**
 * Mosaic: the one card about writing today's cards. With none today, when they come and a button
 * to write them now (or, with nothing in training, where to pick an ability); after a run that
 * wrote no card, why, with the button to try again.
 */
@Composable
private fun WriteCard(empty: Boolean, nothingPlanned: Boolean, failure: String?, onWriteNow: () -> Unit) {
    val context = LocalContext.current
    val task = remember { FeedFlow.task(context) }
    val time = task?.let { "%02d:%02d".format(Locale.ROOT, it.timeOfDayHour, it.timeOfDayMinute) }
        ?: "%02d:%02d".format(Locale.ROOT, FeedFlow.DEFAULT_HOUR, FeedFlow.DEFAULT_MINUTE)
    FeedCard {
        Column(Modifier.padding(16.dp)) {
            if (empty) {
                Text(stringResource(R.string.nm_growth_empty_title), fontSize = 16.sp, lineHeight = 22.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurface)
                Spacer(Modifier.height(4.dp))
                Text(
                    if (nothingPlanned) stringResource(R.string.nm_growth_empty_nothing) else stringResource(R.string.nm_growth_empty_body, time),
                    fontSize = 15.sp, lineHeight = 22.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.86f),
                )
            }
            if (failure != null && !nothingPlanned) {
                if (empty) Spacer(Modifier.height(8.dp))
                Text(failure, fontSize = 14.sp, lineHeight = 20.sp, color = MaterialTheme.colorScheme.error)
            }
            if (!nothingPlanned) {
                Spacer(Modifier.height(14.dp))
                Button(
                    onClick = onWriteNow,
                    shape = CircleShape,
                    colors = ButtonDefaults.buttonColors(containerColor = MuseTones.action, contentColor = Color.White),
                    modifier = Modifier.fillMaxWidth().height(46.dp),
                ) { Text(stringResource(R.string.nm_growth_write_now), fontSize = 15.sp, fontWeight = FontWeight.SemiBold) }
            }
        }
    }
}

/** Mosaic: cards from earlier days that still wait for an answer live in the calendar; this line points there. */
@Composable
private fun EarlierLine(count: Int, onOpen: () -> Unit) {
    Text(
        androidx.compose.ui.res.pluralStringResource(R.plurals.nm_growth_earlier_open, count, count),
        fontSize = 13.sp,
        lineHeight = 18.sp,
        color = MuseTones.action,
        modifier = Modifier.fillMaxWidth().clickable(onClick = onOpen).padding(horizontal = 20.dp, vertical = 6.dp),
    )
}

@Composable
private fun GeneratingCard() {
    FeedCard {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp, color = MuseTones.action)
            Spacer(Modifier.width(10.dp))
            Text(stringResource(R.string.nm_growth_writing), fontSize = 15.sp, color = MaterialTheme.colorScheme.onSurface)
        }
    }
}

/**
 * Mosaic: the training settings behind the header's sliders. The skill each ability is trained
 * with, the knowledge the cards are made from, then the steering sentence, the routine's switch
 * and time, and "Write it now".
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FeedSettingsSheet(
    onDismiss: () -> Unit,
    onEditRoutine: (String) -> Unit,
    onOpenSkill: (String) -> Unit,
    onOpenSkills: () -> Unit,
    onOpenFolders: () -> Unit,
) {
    val context = LocalContext.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val prefs by FeedStore.preferences.collectAsState()
    var text by remember(prefs) { mutableStateOf(prefs) }
    val taskStore = remember { ScheduledTaskStore(context) }
    // Mosaic: one subscription and one read of the stored tasks, not one per recomposition.
    val tasks by remember(taskStore) { taskStore.observe() }.collectAsState(initial = remember(taskStore) { taskStore.all() })
    val task = remember(tasks) { FeedFlow.taskId(context)?.let { id -> tasks.firstOrNull { it.id == id } } }
    val generating by FeedFlow.generating.collectAsState()
    val sources by produceState<io.github.nanomuse.growth.GrowthSources.Snapshot?>(null) {
        value = runCatching { io.github.nanomuse.growth.GrowthSources.snapshot(context) }.getOrNull()
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = ChatColors.background) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 24.dp)) {
            Text(stringResource(R.string.nm_growth_settings_title), fontSize = 20.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurface)
            Spacer(Modifier.height(4.dp))
            Text(stringResource(R.string.nm_growth_settings_desc), fontSize = 13.sp, lineHeight = 18.sp, color = ChatColors.secondaryText)
            sources?.let { s ->
                GrowthSkillsSection(s, onOpenSkill = { onDismiss(); onOpenSkill(it) }, onOpenSkills = { onDismiss(); onOpenSkills() })
                GrowthKnowledgeSection(s, onOpenFolders = { onDismiss(); onOpenFolders() })
            }
            Spacer(Modifier.height(18.dp))
            Text(stringResource(R.string.nm_growth_settings_steer), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurface)
            Spacer(Modifier.height(2.dp))
            Text(stringResource(R.string.nm_growth_settings_steer_desc), fontSize = 12.sp, lineHeight = 17.sp, color = ChatColors.secondaryText)
            Spacer(Modifier.height(8.dp))
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                modifier = Modifier.fillMaxWidth().heightIn(min = 120.dp),
                shape = RoundedCornerShape(14.dp),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = MuseTones.action,
                    unfocusedBorderColor = MuseTones.hairline,
                ),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Default),
                textStyle = MaterialTheme.typography.bodyMedium.copy(fontSize = 15.sp, lineHeight = 22.sp),
            )
            Spacer(Modifier.height(16.dp))
            Surface(shape = RoundedCornerShape(14.dp), color = MuseTones.fill, modifier = Modifier.fillMaxWidth()) {
                Column {
                    Row(Modifier.padding(horizontal = 14.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(stringResource(R.string.nm_feed_routine_switch), fontSize = 15.sp, color = MaterialTheme.colorScheme.onSurface)
                            val time = task?.let { "%02d:%02d".format(java.util.Locale.ROOT, it.timeOfDayHour, it.timeOfDayMinute) }
                            Text(
                                if (time != null) stringResource(R.string.nm_feed_routine_time, time) else stringResource(R.string.nm_growth_routine_needs_model),
                                fontSize = 12.sp,
                                color = ChatColors.secondaryText,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.clickable(enabled = task != null) { task?.let { onEditRoutine(it.id) } },
                            )
                        }
                        Switch(checked = task?.enabled == true, enabled = task != null, onCheckedChange = { FeedFlow.setEnabled(context, it) })
                    }
                    HorizontalDivider(color = MuseTones.hairline, modifier = Modifier.padding(horizontal = 14.dp))
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .clickable(enabled = !generating) { FeedFlow.generateNow(context); onDismiss() }
                            .padding(horizontal = 14.dp, vertical = 14.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            stringResource(if (generating) R.string.nm_growth_writing else R.string.nm_growth_write_now),
                            fontSize = 15.sp,
                            color = if (generating) ChatColors.secondaryText else MuseTones.action,
                            fontWeight = FontWeight.Medium,
                        )
                    }
                }
            }
            Spacer(Modifier.height(18.dp))
            Button(
                onClick = { FeedStore.savePreferences(text); onDismiss() },
                shape = CircleShape,
                colors = ButtonDefaults.buttonColors(containerColor = MuseTones.action, contentColor = Color.White),
                modifier = Modifier.fillMaxWidth().height(46.dp),
            ) { Text(stringResource(R.string.nm_feed_save), fontSize = 15.sp, fontWeight = FontWeight.SemiBold) }
        }
    }
}

// ── labels ─────────────────────────────────────────────────────────────────

internal fun todayKey(): String = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date())

/**
 * Mosaic: "Today · Sunday · 1 Nov 2026" for today, "Saturday · 31 Oct 2026" for any other day.
 * No morning or evening: the cards of a day are one set, whenever they were written.
 */
@Composable
internal fun dayLabel(day: String): String {
    val weekdays = stringArrayResource(R.array.nm_weekdays)
    val date = runCatching { SimpleDateFormat("yyyy-MM-dd", Locale.US).parse(day) }.getOrNull() ?: Date()
    val cal = Calendar.getInstance().apply { time = date }
    val weekday = weekdays[(cal.get(Calendar.DAY_OF_WEEK) + 5) % 7] // Calendar: SUNDAY=1 → index 6
    val dateText = DateFormat.getDateInstance(DateFormat.MEDIUM).format(date)
    return if (day == todayKey()) stringResource(R.string.nm_growth_day_today, weekday, dateText)
    else stringResource(R.string.nm_feed_day_past, weekday, dateText)
}

@Composable
private fun typeLabel(type: String): String = stringResource(
    when (type) { // Mosaic: training cards and the weekly report only
        "theory" -> R.string.nm_growth_type_theory
        "challenge" -> R.string.nm_growth_type_challenge
        "review" -> R.string.nm_growth_type_review
        "action" -> R.string.nm_growth_type_action
        "weekly" -> R.string.nm_growth_type_weekly
        else -> R.string.nm_growth_type_practice
    },
)

private fun defaultEmoji(type: String): String = when (type) {
    "theory" -> "📖" // Mosaic
    "challenge" -> "🏆"
    "review" -> "🔁"
    "action" -> "🚶"
    "weekly" -> "📊"
    else -> "🏋️"
}
