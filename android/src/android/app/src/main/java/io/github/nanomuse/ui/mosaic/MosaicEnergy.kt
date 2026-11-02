package io.github.nanomuse.ui.mosaic

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.openminis.app.R

/**
 * A record's mood as energy: a small battery whose five cells fill the better the person felt.
 * The mood scale runs from 1 "great" to 5 "awful", so great is a full battery and awful one cell;
 * the cells go from green when full to red when nearly empty.
 */
@Composable
internal fun MosaicEnergy(mood: Int, modifier: Modifier = Modifier) {
    val level = energyOf(mood)
    val fill = ENERGY_COLORS[level - 1]
    val outline = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f)
    val empty = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f)
    val label = stringResource(R.string.nm_mosaic_energy_a11y, level)
    Canvas(modifier.size(width = 30.dp, height = 15.dp).semantics { contentDescription = label }) {
        val stroke = 1.4.dp.toPx()
        val nub = 2.5.dp.toPx()
        val bodyWidth = size.width - nub - stroke
        val bodyHeight = size.height - stroke
        drawRoundRect(
            outline,
            topLeft = Offset(stroke / 2, stroke / 2),
            size = Size(bodyWidth, bodyHeight),
            cornerRadius = CornerRadius(3.dp.toPx()),
            style = Stroke(stroke),
        )
        val nubHeight = size.height * 0.4f
        drawRoundRect(
            outline,
            topLeft = Offset(size.width - nub, (size.height - nubHeight) / 2),
            size = Size(nub, nubHeight),
            cornerRadius = CornerRadius(1.dp.toPx()),
        )
        val inset = stroke + 1.5.dp.toPx()
        val gap = 1.3.dp.toPx()
        val innerWidth = bodyWidth + stroke - inset * 2
        val innerHeight = size.height - inset * 2
        val cell = (innerWidth - gap * (CELLS - 1)) / CELLS
        for (i in 0 until CELLS) {
            drawRoundRect(
                if (i < level) fill else empty,
                topLeft = Offset(inset + i * (cell + gap), inset),
                size = Size(cell, innerHeight),
                cornerRadius = CornerRadius(1.dp.toPx()),
            )
        }
    }
}

/** Cells lit for [mood]: 5 for "great" (1) down to 1 for "awful" (5). */
internal fun energyOf(mood: Int): Int = (CELLS + 1 - mood).coerceIn(1, CELLS)

private const val CELLS = 5

/** From one cell (red) to five (green). */
private val ENERGY_COLORS = listOf(
    Color(0xFFFF453A),
    Color(0xFFFF8A1F),
    Color(0xFFF5B400),
    Color(0xFF7ACB3F),
    Color(0xFF34C759),
)
