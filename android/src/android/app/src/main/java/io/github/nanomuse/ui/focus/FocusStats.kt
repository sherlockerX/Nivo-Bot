package io.github.nanomuse.ui.focus

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.Canvas
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.Alignment
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import io.github.nanomuse.focus.*
import java.time.LocalDate
import java.time.DayOfWeek
import java.time.temporal.TemporalAdjusters

/** 汇总实际专注区间，标签多重归属时不误当互斥占比。 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun FocusStats(rows:List<FocusSession>,spans:List<FocusSpan>) {
    var period by remember { mutableStateOf(0) }
    val today=LocalDate.now()
    val start=when(period){1->today.with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY));2->today.withDayOfMonth(1);3->today.withDayOfYear(1);else->today}
    val end=today.plusDays(1)
    val total=FocusStatistics.duration(spans,start,end)
    Column(verticalArrangement=Arrangement.spacedBy(14.dp)) {
        FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
            listOf(R.string.nm_focus_day,R.string.nm_focus_week,R.string.nm_focus_month,R.string.nm_focus_year).forEachIndexed { index,label ->
                FilterChip(selected=period==index,onClick={period=index},label={Text(stringResource(label))}) }
        }
        FocusPanel { Text(formatFocusDuration(total),style=MaterialTheme.typography.headlineLarge)
            Text(stringResource(R.string.nm_focus_stats_hint),style=MaterialTheme.typography.bodySmall) }
        val byId=rows.associateBy { it.id }
        val groups=spans.groupBy { byId[it.sessionId]?.groupName.orEmpty() }.map { (group,values)->group to FocusStatistics.duration(values,start,end) }.filter { it.second>0 }.sortedByDescending { it.second }
        FocusPanel { Text(stringResource(R.string.nm_focus_distribution),style=MaterialTheme.typography.titleMedium)
            if(groups.isEmpty()) Text(stringResource(R.string.nm_focus_empty))
            else {
                val colors=listOf(Color(0xFF789B86),Color(0xFF8298AC),Color(0xFFB39879),Color(0xFF9C8AA7),Color(0xFF8B9A9A))
                Box(Modifier.fillMaxWidth().height(190.dp),contentAlignment=Alignment.Center) {
                    Canvas(Modifier.size(176.dp)) {
                        var startAngle=-90f
                        groups.forEachIndexed { index,entry ->
                            val angle=entry.second.toFloat()/total*360f
                            drawArc(colors[index%colors.size],startAngle,angle,false,style=Stroke(width=24.dp.toPx()))
                            startAngle+=angle
                        }
                    }
                    Text(formatFocusDuration(total),style=MaterialTheme.typography.titleMedium)
                }
            }
            groups.forEach { (group,duration)->
                Text((group.ifBlank { stringResource(R.string.nm_todo_ungrouped) })+" · "+formatFocusDuration(duration))
                LinearProgressIndicator(progress={if(total>0) duration.toFloat()/total else 0f},modifier=Modifier.fillMaxWidth())
            }
        }
    }
}
