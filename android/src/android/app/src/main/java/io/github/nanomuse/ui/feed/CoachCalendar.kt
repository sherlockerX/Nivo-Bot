package io.github.nanomuse.ui.feed

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openminis.app.R
import com.openminis.app.ui.theme.ChatColors
import io.github.nanomuse.feed.FeedPost
import io.github.nanomuse.feed.FeedStore
import io.github.nanomuse.growth.GrowthStore
import io.github.nanomuse.ui.home.MuseTones
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle

/**
 * Mosaic: the training calendar behind the Coach tab's calendar button. A month at a time, with a
 * dot under every day that has cards; under it the chosen day's cards as the page showed them,
 * with the answers and reviews, still open to an answer. The Coach tab itself shows today only.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun CoachCalendarSheet(
    posts: List<FeedPost>,
    initialDay: String,
    onDismiss: () -> Unit,
    onDiscuss: (FeedPost) -> Unit,
    onInfo: (FeedPost) -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val responses by GrowthStore.responses.collectAsState()
    val today = remember { LocalDate.now() }
    // Older days are pruned from disk (FeedStore.KEEP_DAYS), so the calendar starts at the month they reach back to.
    val earliest = remember(today) { today.minusDays(FeedStore.KEEP_DAYS.toLong()).withDayOfMonth(1) }
    var selectedValue by rememberSaveable { mutableStateOf(initialDay) }
    var monthValue by rememberSaveable { mutableStateOf(initialDay.take(7) + "-01") }
    val selected = runCatching { LocalDate.parse(selectedValue) }.getOrDefault(today)
    val month = runCatching { LocalDate.parse(monthValue) }.getOrDefault(today.withDayOfMonth(1))
    val byDay = remember(posts) { posts.groupBy { it.day } }
    val dayPosts = byDay[selected.toString()].orEmpty()
    val locale = LocalContext.current.resources.configuration.locales[0]
    val monthTitle = remember(month, locale) {
        DateTimeFormatter.ofPattern(android.text.format.DateFormat.getBestDateTimePattern(locale, "yMMMM"), locale).format(month)
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = MuseTones.canvas) {
        LazyColumn(Modifier.fillMaxWidth(), contentPadding = PaddingValues(bottom = 28.dp)) {
            item(key = "title") {
                Text(
                    stringResource(R.string.nm_growth_calendar),
                    fontSize = 20.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.padding(horizontal = 20.dp),
                )
            }
            item(key = "month") {
                Surface(
                    shape = RoundedCornerShape(18.dp),
                    color = MuseTones.surface,
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 8.dp),
                ) {
                    Column(Modifier.padding(12.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            IconButton(enabled = month > earliest, onClick = { monthValue = month.minusMonths(1).toString() }) {
                                Icon(Icons.AutoMirrored.Filled.KeyboardArrowLeft, stringResource(R.string.nm_mosaic_previous))
                            }
                            Text(
                                monthTitle,
                                style = MaterialTheme.typography.titleMedium,
                                textAlign = TextAlign.Center,
                                modifier = Modifier.weight(1f),
                            )
                            IconButton(enabled = month < today.withDayOfMonth(1), onClick = { monthValue = month.plusMonths(1).toString() }) {
                                Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, stringResource(R.string.nm_mosaic_next))
                            }
                        }
                        MonthGrid(month, selected, today, byDay.keys) { selectedValue = it.toString() }
                        Text(
                            stringResource(R.string.nm_growth_calendar_kept, FeedStore.KEEP_DAYS),
                            fontSize = 12.sp, color = ChatColors.secondaryText,
                            modifier = Modifier.padding(start = 4.dp, top = 8.dp),
                        )
                    }
                }
            }
            item(key = "day") {
                Column {
                    DayTitle(dayLabel(selected.toString()))
                    Text(
                        if (dayPosts.isEmpty()) stringResource(R.string.nm_growth_calendar_none)
                        else pluralStringResource(R.plurals.nm_growth_calendar_day, dayPosts.size, dayPosts.size, dayPosts.count { it.id in responses }),
                        fontSize = 13.sp, color = ChatColors.secondaryText,
                        modifier = Modifier.padding(start = 20.dp, end = 20.dp, bottom = 4.dp),
                    )
                }
            }
            items(dayPosts, key = { it.id }) { post ->
                PostCard(post = post, onDiscuss = { onDiscuss(post) }, onInfo = { onInfo(post) })
            }
        }
    }
}

/** One month, Monday first; the chosen day filled, today ringed, a dot under days with cards, the future not selectable. */
@Composable
private fun MonthGrid(first: LocalDate, selected: LocalDate, today: LocalDate, days: Set<String>, onSelect: (LocalDate) -> Unit) {
    val locale = LocalContext.current.resources.configuration.locales[0]
    val leading = first.dayOfWeek.value - 1
    val length = first.lengthOfMonth()
    Column {
        Row {
            DayOfWeek.entries.forEach { day ->
                Box(Modifier.weight(1f).height(28.dp), contentAlignment = Alignment.Center) {
                    Text(day.getDisplayName(TextStyle.NARROW, locale), style = MaterialTheme.typography.labelMedium, color = ChatColors.secondaryText)
                }
            }
        }
        repeat((leading + length + 6) / 7) { week ->
            Row {
                repeat(7) { weekday ->
                    val offset = week * 7 + weekday - leading
                    val date = first.plusDays(offset.toLong())
                    val inMonth = offset in 0 until length
                    val future = date.isAfter(today)
                    val chosen = inMonth && date == selected
                    Box(
                        Modifier
                            .weight(1f)
                            .aspectRatio(1f)
                            .padding(2.dp)
                            .clip(CircleShape)
                            .then(
                                when {
                                    chosen -> Modifier.background(MuseTones.action)
                                    inMonth && date == today -> Modifier.border(1.dp, MuseTones.action, CircleShape)
                                    else -> Modifier
                                },
                            )
                            .clickable(enabled = inMonth && !future) { onSelect(date) },
                        contentAlignment = Alignment.Center,
                    ) {
                        if (inMonth) Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Text(
                                "${date.dayOfMonth}",
                                fontSize = 14.sp,
                                color = when {
                                    chosen -> Color.White
                                    future -> ChatColors.secondaryText.copy(alpha = 0.5f)
                                    else -> MaterialTheme.colorScheme.onSurface
                                },
                            )
                            val dot = when {
                                date.toString() !in days -> Color.Transparent
                                chosen -> Color.White
                                else -> MuseTones.action
                            }
                            Box(Modifier.size(5.dp).background(dot, CircleShape))
                        }
                    }
                }
            }
        }
    }
}
