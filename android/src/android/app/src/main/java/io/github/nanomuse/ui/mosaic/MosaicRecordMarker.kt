package io.github.nanomuse.ui.mosaic

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openminis.app.R
import io.github.nanomuse.mosaic.RecordDayStatus
import io.github.nanomuse.mosaic.recordDayStatus
import java.time.LocalDate

/** 各级日历共用的状态颜色，深色主题保留足够的对比度。 */
internal data class RecordRingColors(val recorded: Color, val missing: Color) {
    /** 未来日期及未加载的日期没有状态圈。 */
    fun forStatus(status: RecordDayStatus): Color? = when (status) {
        RecordDayStatus.RECORDED -> recorded
        RecordDayStatus.MISSING -> missing
        else -> null
    }
}

/** 返回适合当前主题的红绿圈颜色。 */
@Composable
internal fun recordRingColors(): RecordRingColors =
    if (MaterialTheme.colorScheme.surface.luminance() < .5f) RecordRingColors(Color(0xFF81C784), Color(0xFFEF9A9A))
    else RecordRingColors(Color(0xFF2E7D32), Color(0xFFC62828))

/** 日期数字上的状态圈；选中和今日边框仍由外部日历单元格负责。 */
@Composable
internal fun MosaicDateNumber(day: Long, today: Long, entryCount: Int?) {
    val status = recordDayStatus(day, today, entryCount)
    val color = recordRingColors().forStatus(status)
    val label = stringResource(when (status) {
        RecordDayStatus.RECORDED -> R.string.nm_mosaic_recorded_marker
        RecordDayStatus.MISSING -> R.string.nm_mosaic_missing_marker
        RecordDayStatus.FUTURE -> R.string.nm_mosaic_future_marker
        RecordDayStatus.LOADING -> R.string.nm_mosaic_loading_marker
    })
    val date = LocalDate.ofEpochDay(day)
    Box(Modifier.size(23.dp).then(if (color == null) Modifier else Modifier.border(1.5.dp, color, CircleShape))
        .semantics { contentDescription = "$date, $label" }, contentAlignment = Alignment.Center) {
        Text(date.dayOfMonth.toString(), fontSize = 11.sp, lineHeight = 12.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = if (day > today) .6f else 1f))
    }
}

/** 图例用文字补充颜色含义，未记录不会与数据加载状态混淆。 */
@Composable
@OptIn(ExperimentalLayoutApi::class)
internal fun MosaicRecordLegend() {
    val colors = recordRingColors()
    FlowRow(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        listOf(colors.recorded to R.string.nm_mosaic_recorded_marker, colors.missing to R.string.nm_mosaic_missing_marker).forEach { (color, label) ->
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Box(Modifier.size(12.dp).border(BorderStroke(1.5.dp, color), CircleShape))
                Text(stringResource(label), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        Text(stringResource(R.string.nm_mosaic_future_no_ring), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
