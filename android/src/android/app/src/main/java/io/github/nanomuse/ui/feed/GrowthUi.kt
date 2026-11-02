package io.github.nanomuse.ui.feed

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringArrayResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openminis.app.R
import com.openminis.app.ui.markdown.MarkdownText
import com.openminis.app.ui.theme.ChatColors
import io.github.nanomuse.feed.FeedPost
import androidx.compose.ui.text.style.TextOverflow
import io.github.nanomuse.growth.GrowthFlow
import io.github.nanomuse.growth.GrowthSources
import io.github.nanomuse.growth.GrowthStore
import io.github.nanomuse.growth.GrowthTrack
import io.github.nanomuse.ui.home.MuseTones
import java.util.Locale

/**
 * Mosaic: the top of the Coach tab. The ability in training with its level and how far the next level
 * is; the others as small pills; when the ability reaches the goal, the offer to move on.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun GrowthCard(today: List<FeedPost>, onOpen: () -> Unit) {
    val context = LocalContext.current
    val state by GrowthStore.state.collectAsState()
    val responses by GrowthStore.responses.collectAsState()
    val levels = stringArrayResource(R.array.nm_growth_levels)
    val focus = state.focus
    val cards = today.filter { it.prompt.isNotBlank() && it.track != null }
    val answered = cards.count { it.id in responses }
    val streak = remember(responses) { GrowthStore.streak() }
    Surface(
        onClick = onOpen,
        shape = RoundedCornerShape(18.dp),
        color = MuseTones.surface,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 6.dp),
    ) {
        Column(Modifier.padding(16.dp)) {
            Text(stringResource(R.string.nm_growth_focus_title), fontSize = 13.sp, color = ChatColors.secondaryText)
            Spacer(Modifier.height(4.dp))
            if (focus == null) {
                Text(
                    stringResource(if (state.tracks.any { it.status == GrowthStore.QUEUED }) R.string.nm_growth_no_focus else R.string.nm_growth_all_done),
                    fontSize = 15.sp, lineHeight = 21.sp, color = MaterialTheme.colorScheme.onSurface,
                )
            } else {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(focus.title(context), fontSize = 18.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurface, modifier = Modifier.weight(1f))
                    Text(levelLabel(focus.level, levels), fontSize = 14.sp, fontWeight = FontWeight.Medium, color = MuseTones.action)
                }
                Spacer(Modifier.height(10.dp))
                val window = focus.scores.takeLast(GrowthStore.WINDOW)
                LinearProgressIndicator(
                    progress = { window.size / GrowthStore.WINDOW.toFloat() },
                    modifier = Modifier.fillMaxWidth().height(6.dp),
                    color = MuseTones.action,
                    trackColor = MuseTones.fill,
                )
                Spacer(Modifier.height(6.dp))
                val average = if (window.isEmpty()) "-" else String.format(Locale.ROOT, "%.1f", window.average())
                Text(
                    (if (focus.challenge) stringResource(R.string.nm_growth_challenge_ready)
                    else stringResource(R.string.nm_growth_progress, window.size, GrowthStore.WINDOW, average)) + " · " +
                        stringResource(R.string.nm_growth_goal, levels.getOrElse(state.target - 1) { "" }),
                    fontSize = 12.sp, color = if (focus.challenge) MuseTones.action else ChatColors.secondaryText,
                )
            }
            if (cards.isNotEmpty() || streak > 0) {
                Spacer(Modifier.height(4.dp))
                Text(
                    listOfNotNull(
                        if (cards.isNotEmpty()) stringResource(R.string.nm_growth_today, answered, cards.size) else null,
                        if (streak > 0) stringResource(R.string.nm_growth_streak, streak) else null,
                    ).joinToString(" · "),
                    fontSize = 12.sp, color = ChatColors.secondaryText,
                )
            }
            val others = state.tracks.filter { it.id != focus?.id }
            if (others.isNotEmpty()) {
                Spacer(Modifier.height(12.dp))
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    others.forEach { t ->
                        Text(
                            t.title(context) + " · " + statusLabel(t, levels),
                            fontSize = 12.sp,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = if (t.status == GrowthStore.PAUSED) 0.45f else 0.8f),
                            modifier = Modifier.background(MuseTones.fill, CircleShape).padding(horizontal = 10.dp, vertical = 5.dp),
                        )
                    }
                }
            }
            state.promotion?.let { done ->
                Spacer(Modifier.height(12.dp))
                Surface(shape = RoundedCornerShape(14.dp), color = MuseTones.fill, modifier = Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(14.dp)) {
                        Text(stringResource(R.string.nm_growth_promote, done.title(context), levels.getOrElse(done.level - 1) { "" }),
                            fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurface)
                        Spacer(Modifier.height(4.dp))
                        val next = state.next()
                        Text(
                            if (next != null) stringResource(R.string.nm_growth_promote_next, next.title(context)) else stringResource(R.string.nm_growth_promote_last),
                            fontSize = 13.sp, lineHeight = 18.sp, color = ChatColors.secondaryText,
                        )
                        Spacer(Modifier.height(10.dp))
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End, verticalAlignment = Alignment.CenterVertically) {
                            TextButton(onClick = { GrowthStore.keepGoing() }) { Text(stringResource(R.string.nm_growth_keep), color = MaterialTheme.colorScheme.onSurface) }
                            if (next != null) {
                                Spacer(Modifier.width(6.dp))
                                Button(
                                    onClick = { GrowthStore.advance() },
                                    shape = CircleShape,
                                    colors = ButtonDefaults.buttonColors(containerColor = MuseTones.action, contentColor = Color.White),
                                ) { Text(stringResource(R.string.nm_growth_switch)) }
                            }
                        }
                    }
                }
            }
        }
    }
}

/** Mosaic: the ability, level, kind of card and course unit a training card belongs to, above its title. */
@Composable
internal fun GrowthTag(post: FeedPost) {
    val context = LocalContext.current
    val state by GrowthStore.state.collectAsState()
    val track = post.track?.let { id -> state.tracks.firstOrNull { it.id == id } } ?: return
    val levels = stringArrayResource(R.array.nm_growth_levels)
    val kind = when (post.type) {
        "theory" -> stringResource(R.string.nm_growth_type_theory)
        "challenge" -> stringResource(R.string.nm_growth_type_challenge)
        "review" -> stringResource(R.string.nm_growth_type_review)
        "action" -> stringResource(R.string.nm_growth_type_action)
        else -> stringResource(R.string.nm_growth_type_practice)
    }
    Text(
        listOfNotNull(track.title(context), levelLabel(post.level.coerceAtLeast(1), levels), kind, post.unit.takeIf { it.isNotBlank() }).joinToString(" · "),
        fontSize = 12.sp, color = MuseTones.action, fontWeight = FontWeight.Medium,
        modifier = Modifier.padding(bottom = 2.dp),
    )
}

/**
 * Mosaic: under a practice card, its question and the answer box; once answered, the answer, then
 * the review in progress or the score and feedback. A review that could not run waits; a tap retries.
 */
@Composable
internal fun GrowthAnswer(post: FeedPost) {
    if (post.prompt.isBlank() || post.track == null) return
    val context = LocalContext.current
    val responses by GrowthStore.responses.collectAsState()
    val grading by GrowthFlow.grading.collectAsState()
    val response = responses[post.id]
    Column(Modifier.fillMaxWidth().padding(start = 56.dp, end = 4.dp, top = 10.dp)) {
        Text(post.prompt, fontSize = 15.sp, lineHeight = 22.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurface)
        Spacer(Modifier.height(8.dp))
        if (response == null) {
            var text by rememberSaveable(post.id) { mutableStateOf("") }
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                placeholder = { Text(stringResource(if (post.type == "action") R.string.nm_growth_action_hint else R.string.nm_growth_answer_hint), fontSize = 14.sp) },
                modifier = Modifier.fillMaxWidth().heightIn(min = 88.dp),
                shape = RoundedCornerShape(14.dp),
                colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = MuseTones.action, unfocusedBorderColor = MuseTones.hairline),
                textStyle = MaterialTheme.typography.bodyMedium.copy(fontSize = 15.sp, lineHeight = 22.sp),
            )
            Spacer(Modifier.height(8.dp))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                Button(
                    onClick = { GrowthFlow.submit(context, post, text) },
                    enabled = text.isNotBlank(),
                    shape = CircleShape,
                    colors = ButtonDefaults.buttonColors(containerColor = MuseTones.action, contentColor = Color.White),
                    contentPadding = PaddingValues(horizontal = 22.dp, vertical = 8.dp),
                ) { Text(stringResource(R.string.nm_growth_submit), fontSize = 14.sp) }
            }
        } else {
            Surface(shape = RoundedCornerShape(12.dp), color = MuseTones.fill, modifier = Modifier.fillMaxWidth()) {
                Text(response.answer, fontSize = 14.sp, lineHeight = 20.sp, color = MaterialTheme.colorScheme.onSurface, modifier = Modifier.padding(10.dp))
            }
            Spacer(Modifier.height(8.dp))
            when {
                response.score != null -> {
                    Text(
                        "●".repeat(response.score) + "○".repeat(4 - response.score) + "  " + stringResource(R.string.nm_growth_score, response.score),
                        fontSize = 13.sp, fontWeight = FontWeight.Medium, color = MuseTones.action,
                    )
                    response.feedback?.takeIf { it.isNotBlank() }?.let {
                        Spacer(Modifier.height(4.dp))
                        MarkdownText(
                            markdown = it,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.86f),
                            style = MaterialTheme.typography.bodyMedium.copy(fontSize = 14.sp, lineHeight = 21.sp),
                        )
                    }
                    // How the card felt steers the next ones within the level.
                    Spacer(Modifier.height(6.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        listOf("too_easy" to R.string.nm_growth_diff_easy, "ok" to R.string.nm_growth_diff_ok, "too_hard" to R.string.nm_growth_diff_hard)
                            .forEach { (value, label) -> Chip(stringResource(label), response.difficulty == value) { GrowthStore.setDifficulty(post.id, value) } }
                    }
                }
                post.id in grading -> Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(modifier = Modifier.size(14.dp), strokeWidth = 2.dp, color = MuseTones.action)
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.nm_growth_grading), fontSize = 13.sp, color = ChatColors.secondaryText)
                }
                else -> Text(
                    stringResource(R.string.nm_growth_ungraded),
                    fontSize = 13.sp, color = MuseTones.action,
                    modifier = Modifier.clickable { GrowthFlow.review(context, post.id) }.padding(vertical = 4.dp),
                )
            }
        }
    }
}

/**
 * Mosaic: every ability with its level and status, the order they are trained in, the level at
 * which the next one starts, adding an ability, and the two files the agent keeps.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
internal fun GrowthSheet(onDismiss: () -> Unit, onChat: (title: String, opener: String) -> Unit = { _, _ -> }) {
    val context = LocalContext.current
    val state by GrowthStore.state.collectAsState()
    // Mosaic: an ability's course is built, or rebuilt, with the agent in a chat of its own, by the course framework.
    fun build(id: String) {
        val opener = GrowthFlow.buildOpener(context, id) ?: return
        val title = GrowthStore.state.value.tracks.firstOrNull { it.id == id }?.title(context) ?: return
        onDismiss()
        onChat(title, opener)
    }
    val levels = stringArrayResource(R.array.nm_growth_levels)
    var adding by remember { mutableStateOf(false) }
    var name by remember { mutableStateOf("") }
    var about by remember { mutableStateOf("") }
    var shown by remember { mutableStateOf<String?>(null) }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = ChatColors.background,
    ) {
        LazyColumn(Modifier.padding(horizontal = 20.dp), contentPadding = PaddingValues(bottom = 28.dp)) {
            item {
                Text(stringResource(R.string.nm_growth_sheet_title), fontSize = 20.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurface)
                Spacer(Modifier.height(4.dp))
                Text(stringResource(R.string.nm_growth_sheet_desc), fontSize = 13.sp, lineHeight = 18.sp, color = ChatColors.secondaryText)
                Spacer(Modifier.height(12.dp))
            }
            itemsIndexed(state.tracks, key = { _, t -> t.id }) { i, t ->
                Column(Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(t.title(context), fontSize = 16.sp, fontWeight = FontWeight.Medium, color = MaterialTheme.colorScheme.onSurface, modifier = Modifier.weight(1f))
                        Text(statusLabel(t, levels), fontSize = 13.sp, color = if (t.status == GrowthStore.FOCUS) MuseTones.action else ChatColors.secondaryText)
                    }
                    t.about?.let { Text(it, fontSize = 12.sp, color = ChatColors.secondaryText) }
                    val books = remember(t.skill) { GrowthStore.bookCards(t.skill).size }
                    Text(
                        if (books > 0) stringResource(R.string.nm_growth_course_books, books) else stringResource(R.string.nm_growth_course_none),
                        fontSize = 12.sp, color = ChatColors.secondaryText,
                    )
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                        if (t.status != GrowthStore.FOCUS && t.status != GrowthStore.PAUSED) SmallAction(stringResource(R.string.nm_growth_set_focus)) { GrowthStore.setFocus(t.id) }
                        if (i > 0) SmallAction(stringResource(R.string.nm_growth_move_up)) { GrowthStore.moveUp(t.id) }
                        if (t.status != GrowthStore.FOCUS) {
                            if (t.status == GrowthStore.PAUSED) SmallAction(stringResource(R.string.nm_growth_resume)) { GrowthStore.setPaused(t.id, false) }
                            else SmallAction(stringResource(R.string.nm_growth_pause)) { GrowthStore.setPaused(t.id, true) }
                        }
                        SmallAction(stringResource(R.string.nm_growth_design)) { build(t.id) }
                        if (t.title != null && t.status != GrowthStore.FOCUS) SmallAction(stringResource(R.string.nm_growth_remove)) { GrowthStore.remove(t.id) }
                    }
                    HorizontalDivider(color = MuseTones.hairline, modifier = Modifier.padding(top = 4.dp))
                }
            }
            item {
                Spacer(Modifier.height(14.dp))
                Text(stringResource(R.string.nm_growth_goal_label), fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurface)
                Spacer(Modifier.height(6.dp))
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    (2..GrowthStore.MAX_LEVEL).forEach { level ->
                        val selected = level == state.target
                        Surface(onClick = { GrowthStore.setTarget(level) }, shape = CircleShape, color = if (selected) MuseTones.action else MuseTones.fill) {
                            Text(levelLabel(level, levels), fontSize = 13.sp, color = if (selected) Color.White else MaterialTheme.colorScheme.onSurface,
                                modifier = Modifier.padding(horizontal = 12.dp, vertical = 7.dp))
                        }
                    }
                }
            }
            item {
                Spacer(Modifier.height(16.dp))
                if (!adding) {
                    SmallAction(stringResource(R.string.nm_growth_add)) { adding = true }
                } else {
                    OutlinedTextField(value = name, onValueChange = { name = it.take(30) }, singleLine = true,
                        label = { Text(stringResource(R.string.nm_growth_add_name)) }, modifier = Modifier.fillMaxWidth())
                    Spacer(Modifier.height(8.dp))
                    OutlinedTextField(value = about, onValueChange = { about = it.take(200) },
                        label = { Text(stringResource(R.string.nm_growth_add_about)) }, modifier = Modifier.fillMaxWidth().heightIn(min = 72.dp))
                    Spacer(Modifier.height(6.dp))
                    Text(stringResource(R.string.nm_growth_add_desc), fontSize = 12.sp, lineHeight = 17.sp, color = ChatColors.secondaryText)
                    Spacer(Modifier.height(8.dp))
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End, verticalAlignment = Alignment.CenterVertically) {
                        TextButton(
                            onClick = { GrowthStore.add(name, about); name = ""; about = ""; adding = false },
                            enabled = name.isNotBlank(),
                        ) { Text(stringResource(R.string.nm_growth_add_save), color = if (name.isNotBlank()) MaterialTheme.colorScheme.onSurface else ChatColors.secondaryText) }
                        Spacer(Modifier.width(6.dp))
                        Button(
                            onClick = { val id = GrowthStore.add(name, about); name = ""; about = ""; adding = false; build(id) },
                            enabled = name.isNotBlank(),
                            shape = CircleShape,
                            colors = ButtonDefaults.buttonColors(containerColor = MuseTones.action, contentColor = Color.White),
                        ) { Text(stringResource(R.string.nm_growth_add_design)) }
                    }
                }
            }
            item {
                Spacer(Modifier.height(16.dp))
                // The framework the person keeps from the ability in training, grown by the coach unit by unit.
                state.focus?.let { f ->
                    FileSection(stringResource(R.string.nm_growth_framework, f.title(context)), shown == "framework", { shown = if (shown == "framework") null else "framework" }) {
                        GrowthStore.framework(f.skill)
                    }
                }
                val observationsTitle = stringResource(R.string.nm_growth_observations)
                FileSection(stringResource(R.string.nm_growth_memory), shown == "memory", { shown = if (shown == "memory") null else "memory" }) {
                    listOfNotNull(
                        GrowthStore.read(GrowthStore.memoryFile()).ifEmpty { null },
                        GrowthStore.observations().takeIf { it.isNotEmpty() }?.let { "**$observationsTitle**\n\n" + it.joinToString("\n") },
                    ).joinToString("\n\n")
                }
                FileSection(stringResource(R.string.nm_growth_principles), shown == "principles", { shown = if (shown == "principles") null else "principles" }) {
                    GrowthStore.read(GrowthStore.principlesFile())
                }
            }
        }
    }
}

/** Mosaic: in the training settings, each ability with the skill that trains it; a tap opens the skill. */
@Composable
internal fun GrowthSkillsSection(s: GrowthSources.Snapshot, onOpenSkill: (String) -> Unit, onOpenSkills: () -> Unit) {
    val context = LocalContext.current
    val levels = stringArrayResource(R.array.nm_growth_levels)
    SettingsHeading(stringResource(R.string.nm_growth_settings_skills), stringResource(R.string.nm_growth_settings_skills_desc))
    Surface(shape = RoundedCornerShape(14.dp), color = MuseTones.fill, modifier = Modifier.fillMaxWidth()) {
        Column {
            s.skills.forEach { row ->
                Column(
                    Modifier.fillMaxWidth().clickable(enabled = row.name != null) { onOpenSkill(row.skillId) }
                        .padding(horizontal = 14.dp, vertical = 10.dp),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(row.track.title(context), fontSize = 15.sp, color = MaterialTheme.colorScheme.onSurface, modifier = Modifier.weight(1f))
                        Text(statusLabel(row.track, levels), fontSize = 12.sp,
                            color = if (row.track.status == GrowthStore.FOCUS) MuseTones.action else ChatColors.secondaryText)
                    }
                    Text(
                        if (row.name != null) listOfNotNull(row.skillId, row.description?.takeIf { it.isNotBlank() }).joinToString(" · ")
                        else stringResource(R.string.nm_growth_settings_skill_missing, row.skillId),
                        fontSize = 12.sp, lineHeight = 17.sp, maxLines = 2, overflow = TextOverflow.Ellipsis,
                        color = if (row.name != null) ChatColors.secondaryText else MaterialTheme.colorScheme.error,
                    )
                    // Mosaic: how far the course behind the ability has come.
                    Text(stringResource(R.string.nm_growth_settings_books, row.books, row.framework), fontSize = 12.sp, color = ChatColors.secondaryText)
                }
                HorizontalDivider(color = MuseTones.hairline, modifier = Modifier.padding(horizontal = 14.dp))
            }
            Text(
                stringResource(R.string.nm_growth_settings_all_skills, s.allSkills),
                fontSize = 15.sp, color = MuseTones.action,
                modifier = Modifier.fillMaxWidth().clickable(onClick = onOpenSkills).padding(horizontal = 14.dp, vertical = 13.dp),
            )
        }
    }
}

/** Mosaic: in the training settings, what the cards are made from, counted. */
@Composable
internal fun GrowthKnowledgeSection(s: GrowthSources.Snapshot, onOpenFolders: () -> Unit) {
    SettingsHeading(stringResource(R.string.nm_growth_settings_knowledge), stringResource(R.string.nm_growth_settings_knowledge_desc))
    val empty = stringResource(R.string.nm_growth_src_empty)
    Surface(shape = RoundedCornerShape(14.dp), color = MuseTones.fill, modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(horizontal = 14.dp, vertical = 6.dp)) {
            SourceRow(stringResource(R.string.nm_growth_src_user), if (s.userChars > 0) stringResource(R.string.nm_growth_src_chars, s.userChars) else empty)
            SourceRow(stringResource(R.string.nm_growth_src_global), if (s.globalChars > 0) stringResource(R.string.nm_growth_src_chars, s.globalChars) else empty)
            SourceRow(stringResource(R.string.nm_growth_src_mosaic), stringResource(R.string.nm_growth_src_mosaic_value, s.mosaicEntries, s.mosaicDays))
            SourceRow(stringResource(R.string.nm_growth_src_diary), stringResource(R.string.nm_growth_src_days, s.diaryDays))
            SourceRow(stringResource(R.string.nm_growth_src_goals), stringResource(R.string.nm_growth_src_count, s.activeGoals))
            SourceRow(stringResource(R.string.nm_growth_src_habits),
                if (s.habits.isEmpty()) empty else stringResource(R.string.nm_growth_src_habits_value, s.habits.size, s.habits.take(6).joinToString(" · ")))
            SourceRow(stringResource(R.string.nm_growth_src_record), stringResource(R.string.nm_growth_src_record_value,
                s.answers, s.graded, s.recall, s.recallDue, s.principles, s.observations))
            Text(stringResource(R.string.nm_growth_src_folders), fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurface, modifier = Modifier.padding(top = 8.dp))
            if (s.folders.isEmpty()) {
                Text(stringResource(R.string.nm_growth_src_no_folders), fontSize = 12.sp, lineHeight = 17.sp, color = ChatColors.secondaryText)
            } else s.folders.forEach { f ->
                Text(
                    "${f.name} · ${f.linuxPath}" + if (f.available) "" else " · " + stringResource(R.string.nm_growth_src_unavailable),
                    fontSize = 12.sp, lineHeight = 17.sp, color = ChatColors.secondaryText,
                )
            }
            Text(
                stringResource(R.string.nm_growth_src_mount),
                fontSize = 14.sp, color = MuseTones.action,
                modifier = Modifier.clickable(onClick = onOpenFolders).padding(vertical = 8.dp),
            )
        }
    }
}

@Composable
private fun SettingsHeading(title: String, description: String) {
    Spacer(Modifier.height(18.dp))
    Text(title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurface)
    Spacer(Modifier.height(2.dp))
    Text(description, fontSize = 12.sp, lineHeight = 17.sp, color = ChatColors.secondaryText)
    Spacer(Modifier.height(8.dp))
}

@Composable
private fun SourceRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.Top) {
        Text(label, fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurface, modifier = Modifier.width(132.dp))
        Text(value, fontSize = 13.sp, lineHeight = 18.sp, color = ChatColors.secondaryText, modifier = Modifier.weight(1f))
    }
}

@Composable
private fun FileSection(title: String, open: Boolean, onToggle: () -> Unit, read: () -> String) {
    Column(Modifier.fillMaxWidth()) {
        Text(
            (if (open) "▾ " else "▸ ") + title,
            fontSize = 15.sp, fontWeight = FontWeight.Medium, color = MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.fillMaxWidth().clickable(onClick = onToggle).padding(vertical = 10.dp),
        )
        if (open) {
            // The section title already names the file; its own top heading would repeat it.
            val text = remember { read().lines().dropWhile { it.startsWith("# ") || it.isBlank() }.joinToString("\n").trim() }
            Surface(shape = RoundedCornerShape(12.dp), color = MuseTones.fill, modifier = Modifier.fillMaxWidth()) {
                if (text.isEmpty()) Text(stringResource(R.string.nm_growth_empty_file), fontSize = 13.sp, color = ChatColors.secondaryText, modifier = Modifier.padding(12.dp))
                else MarkdownText(
                    markdown = text,
                    color = MaterialTheme.colorScheme.onSurface,
                    style = MaterialTheme.typography.bodyMedium.copy(fontSize = 14.sp, lineHeight = 21.sp),
                    modifier = Modifier.padding(12.dp),
                )
            }
        }
    }
}

/**
 * Mosaic: today's recall, one point at a time like a flashcard: the question, then the answer on a
 * tap, then a self-rating that sets when it comes back. Hidden when nothing is due.
 */
@Composable
internal fun RecallCard() {
    val items by GrowthStore.recall.collectAsState()
    val due = remember(items) { GrowthStore.dueRecall() }
    val item = due.firstOrNull() ?: return
    var shown by remember(item.id) { mutableStateOf(false) }
    Surface(
        shape = RoundedCornerShape(18.dp),
        color = MuseTones.surface,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 6.dp),
    ) {
        Column(Modifier.padding(16.dp)) {
            Text(stringResource(R.string.nm_growth_recall_title, due.size), fontSize = 13.sp, color = ChatColors.secondaryText)
            Spacer(Modifier.height(6.dp))
            Text(item.question, fontSize = 16.sp, lineHeight = 22.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurface)
            Spacer(Modifier.height(10.dp))
            if (!shown) {
                Chip(stringResource(R.string.nm_growth_recall_show), false) { shown = true }
            } else {
                Surface(shape = RoundedCornerShape(12.dp), color = MuseTones.fill, modifier = Modifier.fillMaxWidth()) {
                    Text(item.answer, fontSize = 14.sp, lineHeight = 21.sp, color = MaterialTheme.colorScheme.onSurface, modifier = Modifier.padding(10.dp))
                }
                Spacer(Modifier.height(10.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Chip(stringResource(R.string.nm_growth_recall_again), false) { GrowthStore.rateRecall(item.id, "again") }
                    Chip(stringResource(R.string.nm_growth_recall_hard), false) { GrowthStore.rateRecall(item.id, "hard") }
                    Chip(stringResource(R.string.nm_growth_recall_good), true) { GrowthStore.rateRecall(item.id, "good") }
                }
            }
        }
    }
}

@Composable
private fun Chip(label: String, selected: Boolean, onClick: () -> Unit) {
    Surface(onClick = onClick, shape = CircleShape, color = if (selected) MuseTones.action else MuseTones.fill) {
        Text(label, fontSize = 13.sp, color = if (selected) Color.White else MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 7.dp))
    }
}

@Composable
private fun SmallAction(label: String, onClick: () -> Unit) {
    Text(label, fontSize = 13.sp, color = MuseTones.action, modifier = Modifier.clickable(onClick = onClick).padding(horizontal = 6.dp, vertical = 6.dp))
}

private fun levelLabel(level: Int, levels: Array<String>): String = "Lv$level " + levels.getOrElse(level - 1) { "" }

@Composable
private fun statusLabel(t: GrowthTrack, levels: Array<String>): String = levelLabel(t.level, levels) + " · " + stringResource(
    when (t.status) {
        GrowthStore.FOCUS -> R.string.nm_growth_status_focus
        GrowthStore.MAINTAIN -> R.string.nm_growth_status_maintain
        GrowthStore.PAUSED -> R.string.nm_growth_status_paused
        else -> R.string.nm_growth_status_queued
    },
)
