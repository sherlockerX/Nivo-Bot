package io.github.nanomuse.ui.mosaic

import android.content.Context
import androidx.annotation.StringRes
import androidx.compose.foundation.layout.Spacer
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import io.github.nanomuse.mosaic.DayPiece
import io.github.nanomuse.mosaic.MosaicForm
import io.github.nanomuse.mosaic.MosaicStore
import io.github.nanomuse.ui.home.MuseTones
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlin.math.PI
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

// ── The cloud ───────────────────────────────────────────────────────

/**
 * Ten round puffs about a core circle of radius 1 at the origin: each puff is an arc through two
 * neighbouring points of the core, bulging outwards a little more than a half circle, so the
 * outline reads as a round cloud rather than a flower. Stored as centre x, centre y, radius, start
 * and sweep (degrees, clockwise on screen).
 */
private val PUFFS: List<FloatArray> = run {
    val count = 10
    val half = PI / count
    val chord = sin(half)
    val lift = 0.15 * chord
    val radius = sqrt(chord * chord + lift * lift)
    val reach = cos(half) + lift
    List(count) { k ->
        val from = -PI / 2 + 2 * half * k
        val to = from + 2 * half
        val cx = reach * cos(from + half)
        val cy = reach * sin(from + half)
        val start = Math.toDegrees(atan2(sin(from) - cy, cos(from) - cx))
        val end = Math.toDegrees(atan2(sin(to) - cy, cos(to) - cx))
        val sweep = ((end - start) % 360 + 360) % 360
        floatArrayOf(cx.toFloat(), cy.toFloat(), radius.toFloat(), start.toFloat(), sweep.toFloat())
    }
}

/** How far the puffs reach from the centre, in core radii; the cloud's box is twice that. */
private val PUFF_REACH: Float = PUFFS[0].let { (cx, cy, radius) -> sqrt(cx * cx + cy * cy) + radius }

/** A cloud filling a square of [diameter] whose top-left corner is at ([left], [top]). */
fun cloudPath(diameter: Float, left: Float = 0f, top: Float = 0f): Path {
    val core = diameter / 2f / PUFF_REACH
    val cx = left + diameter / 2f
    val cy = top + diameter / 2f
    return Path().apply {
        moveTo(cx, cy - core)
        PUFFS.forEach { (px, py, radius, start, sweep) ->
            arcTo(Rect(Offset(cx + px * core, cy + py * core), radius * core), start, sweep, false)
        }
        close()
    }
}

/** The cloud as a Compose shape: the largest one centred in the box. Every record photo is drawn in it. */
object CloudShape : Shape {
    override fun createOutline(size: Size, layoutDirection: LayoutDirection, density: Density): Outline {
        val d = min(size.width, size.height)
        return Outline.Generic(cloudPath(d, (size.width - d) / 2f, (size.height - d) / 2f))
    }
}

/** A dashed cloud outline: an empty place in a day's shape, or a habit still open. */
fun Modifier.dashedCloud(color: Color): Modifier = drawWithCache {
    val d = min(size.width, size.height)
    val path = cloudPath(d, (size.width - d) / 2f, (size.height - d) / 2f)
    // Round ends and joins, so a dash that meets the notch between two puffs stays a soft curve.
    val stroke = Stroke(
        width = 1.5.dp.toPx(),
        cap = StrokeCap.Round,
        join = StrokeJoin.Round,
        pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 4.dp.toPx())),
    )
    onDrawBehind { drawPath(path, color, style = stroke) }
}

// ── A day's shape ───────────────────────────────────────────────────

/** A shape's places for [count] pieces, and the box they take, in cloud widths. */
class PuzzleLayout(form: MosaicForm, count: Int) {
    private val slots = form.slots(count)
    private val minX = slots.minOf { it.x }
    private val minY = slots.minOf { it.y }

    val size: Int get() = slots.size
    val width: Float = slots.maxOf { it.x } - minX + 1f
    val height: Float = slots.maxOf { it.y } - minY + 1f

    /** The cloud width that fits the whole shape in [maxWidth] by [maxHeight], in their unit. */
    fun unit(maxWidth: Float, maxHeight: Float): Float = min(maxWidth / width, maxHeight / height)

    /** The centre of place [i], in cloud widths from the shape's top-left corner. */
    fun center(i: Int): Offset = Offset(slots[i].x - minX + 0.5f, slots[i].y - minY + 0.5f)
}

/** Each cloud is this share of a place, so neighbours keep a sliver of air between them. */
const val CLOUD_FILL = 0.94f

/** One cloud placed in a canvas: its outline and its box. */
class PlacedCloud(val path: Path, val left: Float, val top: Float, val diameter: Float)

/** The clouds of [layout] centred in the [box] at [topLeft]. */
fun placeClouds(layout: PuzzleLayout, topLeft: Offset, box: Size): List<PlacedCloud> {
    val unit = layout.unit(box.width, box.height)
    val ox = topLeft.x + (box.width - layout.width * unit) / 2f
    val oy = topLeft.y + (box.height - layout.height * unit) / 2f
    val d = unit * CLOUD_FILL
    return List(layout.size) { i ->
        val c = layout.center(i)
        val left = ox + c.x * unit - d / 2f
        val top = oy + c.y * unit - d / 2f
        PlacedCloud(cloudPath(d, left, top), left, top, d)
    }
}

/** The colours of a small shape; a photo draws itself once it is loaded. */
@Immutable
class PuzzleInks(val empty: Color, val ahead: Color, val note: Color, val done: Color, val photo: Color)

@Composable
fun rememberPuzzleInks(): PuzzleInks = PuzzleInks(
    // A wash of the text colour rather than the page grey: at calendar size the empty clouds are
    // the shape, so they must read on white and on black alike.
    empty = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.13f),
    ahead = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.06f),
    note = MuseTones.action.copy(alpha = 0.3f),
    done = MuseTones.action.copy(alpha = 0.55f),
    photo = MuseTones.action.copy(alpha = 0.8f),
)

/** Paints [pieces] into [clouds] in order; places beyond the pieces stay empty clouds. */
fun DrawScope.paintPuzzle(
    clouds: List<PlacedCloud>,
    pieces: List<DayPiece>,
    inks: PuzzleInks,
    images: Map<String, ImageBitmap>,
    ahead: Boolean,
) {
    val open = if (ahead) inks.ahead else inks.empty
    clouds.forEachIndexed { i, cloud ->
        when (val piece = pieces.getOrNull(i)) {
            null -> drawPath(cloud.path, open)
            is DayPiece.Habit -> drawPath(cloud.path, if (piece.done) inks.done else open)
            is DayPiece.Record -> {
                val entry = piece.row.entry
                val image = piece.row.mediaPath?.let { images[it] }
                when {
                    image != null -> clipPath(cloud.path) {
                        drawCropped(image, entry.focusX, entry.focusY, entry.zoom, Offset(cloud.left, cloud.top), Size(cloud.diameter, cloud.diameter))
                    }
                    piece.row.mediaPath != null -> drawPath(cloud.path, inks.photo)
                    else -> drawPath(cloud.path, inks.note)
                }
            }
        }
    }
}

/** A day's shape small enough for a week card or a calendar cell, drawn on one canvas. */
@Composable
fun MosaicMiniPuzzle(
    form: MosaicForm,
    pieces: List<DayPiece>,
    ahead: Boolean,
    images: Map<String, ImageBitmap>,
    modifier: Modifier = Modifier,
) {
    val inks = rememberPuzzleInks()
    val layout = remember(form, pieces.size) { PuzzleLayout(form, pieces.size) }
    Spacer(
        modifier.drawWithCache {
            val clouds = placeClouds(layout, Offset.Zero, size)
            onDrawBehind { paintPuzzle(clouds, pieces, inks, images, ahead) }
        },
    )
}

/**
 * The photos of [paths] decoded at [px], filled in as they arrive. Small shapes share one map per
 * view, so a month loads its pictures once rather than per cell.
 */
@Composable
fun rememberPuzzlePhotos(store: MosaicStore, paths: List<String>, px: Int): Map<String, ImageBitmap> {
    val context = LocalContext.current
    val images = remember { mutableStateMapOf<String, ImageBitmap>() }
    LaunchedEffect(paths, px) {
        if (px > 0) loadPhotos(context, store, paths.filter { it !in images }, px) { path, bitmap -> images[path] = bitmap }
    }
    return images
}

private suspend fun loadPhotos(context: Context, store: MosaicStore, paths: List<String>, px: Int, onLoaded: (String, ImageBitmap) -> Unit) {
    paths.chunked(6).forEach { chunk ->
        coroutineScope {
            chunk.map { path -> async { path to MosaicBitmaps.load(context, store.mediaFile(path), px) } }.awaitAll()
        }.forEach { (path, bitmap) -> if (bitmap != null) onLoaded(path, bitmap) }
    }
}

/** The photo paths among [pieces]. */
fun photoPaths(pieces: List<DayPiece>): List<String> =
    pieces.mapNotNull { (it as? DayPiece.Record)?.row?.mediaPath }

@StringRes
fun formLabel(form: MosaicForm): Int = when (form) {
    MosaicForm.HEART -> R.string.nm_mosaic_form_heart
    MosaicForm.DIAMOND -> R.string.nm_mosaic_form_diamond
    MosaicForm.FLOWER -> R.string.nm_mosaic_form_flower
    MosaicForm.TRIANGLE -> R.string.nm_mosaic_form_triangle
    MosaicForm.RING -> R.string.nm_mosaic_form_ring
    MosaicForm.STAR -> R.string.nm_mosaic_form_star
    MosaicForm.JIGSAW -> R.string.nm_mosaic_form_jigsaw
    MosaicForm.CROSS -> R.string.nm_mosaic_form_cross
}
