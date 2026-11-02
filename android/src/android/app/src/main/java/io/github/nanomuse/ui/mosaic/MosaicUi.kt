package io.github.nanomuse.ui.mosaic

import android.content.Context
import android.graphics.drawable.BitmapDrawable
import android.text.format.DateFormat
import android.util.Log
import android.widget.Toast
import androidx.annotation.StringRes
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.imageLoader
import coil.request.ImageRequest
import coil.request.SuccessResult
import coil.size.Scale
import com.openminis.app.R
import io.github.nanomuse.mosaic.DaySummary
import io.github.nanomuse.mosaic.MosaicCrop
import io.github.nanomuse.mosaic.MosaicEntry
import io.github.nanomuse.mosaic.MosaicEntryRow
import io.github.nanomuse.mosaic.MosaicStore
import io.github.nanomuse.ui.home.MuseTones
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import java.io.File
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.roundToInt

/** Requests between the home shell, the Mosaic tab and the editor, in the manner of `FeedUi`. */
object MosaicUi {
    /** The calendar button in the tab's header: open the date picker. */
    val datePickerOpen = MutableStateFlow(false)

    /** A record was saved for this day (epoch day): the tab shows that day next. */
    val showDay = MutableStateFlow<Long?>(null)

    /** An entry the editor just moved to the bin, with its day: that day's page offers to undo it. */
    val deleted = MutableStateFlow<Pair<String, Long>?>(null)

    /** The bin and stray files are swept once per process, the first time the tab opens. */
    val swept = AtomicBoolean(false)
}

/**
 * A store call from a tap or an effect. A database failure (a full disk, a locked file) becomes a
 * short message instead of a crash; the result says whether the call went through.
 */
suspend fun runStoreCall(context: Context, block: suspend () -> Unit): Boolean = try {
    block()
    true
} catch (e: CancellationException) {
    throw e
} catch (e: Exception) {
    Log.w("Mosaic", "store call failed", e)
    Toast.makeText(context, R.string.nm_mosaic_err_action, Toast.LENGTH_SHORT).show()
    false
}

/** The page's date formats, from patterns in the strings so each language writes dates its own way. */
class MosaicFormats(private val context: Context) {
    private val locale = context.resources.configuration.locales[0]
    private fun pattern(@StringRes id: Int) = DateTimeFormatter.ofPattern(context.getString(id), locale)

    val day: DateTimeFormatter = pattern(R.string.nm_mosaic_fmt_day)
    val monthDay: DateTimeFormatter = pattern(R.string.nm_mosaic_fmt_month_day)
    val yearMonth: DateTimeFormatter = pattern(R.string.nm_mosaic_fmt_year_month)
    val month: DateTimeFormatter = pattern(R.string.nm_mosaic_fmt_month)
    val weekday: DateTimeFormatter = pattern(R.string.nm_mosaic_fmt_weekday)
    val weekCard: DateTimeFormatter = pattern(R.string.nm_mosaic_fmt_week_card)
    val snippet: DateTimeFormatter = pattern(R.string.nm_mosaic_fmt_snippet)
    private val dayOnly = pattern(R.string.nm_mosaic_fmt_day_only)
    private val full = pattern(R.string.nm_mosaic_fmt_full)

    /** A time of day as the phone writes it: its language, and its 12- or 24-hour setting. */
    private val time: DateTimeFormatter = DateTimeFormatter.ofPattern(
        DateFormat.getBestDateTimePattern(locale, if (DateFormat.is24HourFormat(context)) "Hm" else "hma"),
        locale,
    )

    /** "Oct 19–25", "Oct 26–Nov 1", "Dec 28, 2026–Jan 3, 2027": the shortest form that is unambiguous. */
    fun range(start: LocalDate, endInclusive: LocalDate): String = when {
        start.year != endInclusive.year -> full.format(start) + "–" + full.format(endInclusive)
        start.month != endInclusive.month -> monthDay.format(start) + "–" + monthDay.format(endInclusive)
        else -> monthDay.format(start) + "–" + dayOnly.format(endInclusive)
    }

    /**
     * When [entry] was first written, in the time zone it was written in: "08:30", or with its
     * date when it was written on another day than the one it records (a record added later).
     */
    fun recordedAt(entry: MosaicEntry): String {
        val zone = runCatching { ZoneId.of(entry.zoneId) }.getOrDefault(ZoneId.systemDefault())
        val at = Instant.ofEpochMilli(entry.createdAt).atZone(zone)
        return if (at.toLocalDate().toEpochDay() == entry.day) time.format(at)
        else context.getString(R.string.nm_mosaic_recorded_later, monthDay.format(at), time.format(at))
    }
}

@Composable
fun rememberMosaicFormats(): MosaicFormats {
    val context = LocalContext.current
    val configuration = LocalConfiguration.current
    return remember(configuration) { MosaicFormats(context) }
}

/** Decodes archived photos through the app's Coil loader, sized for the box they fill. */
object MosaicBitmaps {
    suspend fun load(context: Context, file: File, sizePx: Int): ImageBitmap? {
        val request = ImageRequest.Builder(context)
            .data(file)
            .size(sizePx.coerceAtLeast(MIN_PX))
            .scale(Scale.FILL)
            // Software bitmaps: the small shapes draw them into a Canvas clipped to each cloud.
            .allowHardware(false)
            .build()
        val result = context.imageLoader.execute(request) as? SuccessResult ?: return null
        return (result.drawable as? BitmapDrawable)?.bitmap?.asImageBitmap()
    }

    private const val MIN_PX = 32
}

@Composable
fun rememberMosaicBitmap(file: File?, sizePx: Int): ImageBitmap? {
    val context = LocalContext.current
    val bitmap by produceState<ImageBitmap?>(initialValue = null, file?.path, sizePx) {
        value = file?.let { MosaicBitmaps.load(context, it, sizePx) }
    }
    return bitmap
}

/** The photo file of an entry, or null for a text-only one. */
fun MosaicEntryRow.photoFile(store: MosaicStore): File? = mediaPath?.let(store::mediaFile)

/** Draws [image] over a [boxSize] box at [topLeft], cropped by [MosaicCrop]. */
fun DrawScope.drawCropped(
    image: ImageBitmap,
    focusX: Float,
    focusY: Float,
    zoom: Float,
    topLeft: androidx.compose.ui.geometry.Offset = androidx.compose.ui.geometry.Offset.Zero,
    boxSize: androidx.compose.ui.geometry.Size = size,
) {
    if (boxSize.width < 1f || boxSize.height < 1f) return
    val src = MosaicCrop.source(image.width, image.height, boxSize.width, boxSize.height, focusX, focusY, zoom)
    val sx = src.left.roundToInt().coerceIn(0, image.width - 1)
    val sy = src.top.roundToInt().coerceIn(0, image.height - 1)
    drawImage(
        image = image,
        srcOffset = IntOffset(sx, sy),
        srcSize = IntSize(
            src.width.roundToInt().coerceIn(1, image.width - sx),
            src.height.roundToInt().coerceIn(1, image.height - sy),
        ),
        dstOffset = IntOffset(topLeft.x.roundToInt(), topLeft.y.roundToInt()),
        dstSize = IntSize(boxSize.width.roundToInt(), boxSize.height.roundToInt()),
        filterQuality = FilterQuality.Medium,
    )
}

/** An entry's photo filling its box, with the entry's own focus and zoom. */
@Composable
fun MosaicPhoto(row: MosaicEntryRow, store: MosaicStore, box: Dp, modifier: Modifier = Modifier) {
    val px = with(LocalDensity.current) { box.roundToPx() }
    val image = rememberMosaicBitmap(row.photoFile(store), px)
    Canvas(modifier) {
        if (image != null) drawCropped(image, row.entry.focusX, row.entry.focusY, row.entry.zoom)
    }
}

/** The tint of a day that has words or a done mark but no photo: low, so photos stay the subject. */
internal val noteTint = MuseTones.action.copy(alpha = 0.16f)

// ── Shared pieces of the five views ─────────────────────────────────

/** The period's name between two arrows; the name opens the date picker. */
@Composable
fun MosaicDateBar(
    title: String,
    subtitle: String?,
    onPrevious: () -> Unit,
    onNext: () -> Unit,
    onPick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier.fillMaxWidth().padding(horizontal = 8.dp),
    ) {
        IconButton(onClick = onPrevious) {
            Icon(
                Icons.AutoMirrored.Filled.KeyboardArrowLeft,
                contentDescription = stringResource(R.string.nm_mosaic_previous),
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier
                .weight(1f)
                .heightIn(min = 48.dp)
                .clip(RoundedCornerShape(12.dp))
                .clickable(role = Role.Button, onClickLabel = stringResource(R.string.nm_mosaic_pick_date), onClick = onPick)
                .padding(vertical = 4.dp),
            verticalArrangement = Arrangement.Center,
        ) {
            Text(
                title,
                fontSize = 17.sp,
                lineHeight = 22.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (subtitle != null) {
                Text(
                    subtitle,
                    fontSize = 12.sp,
                    lineHeight = 16.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        IconButton(onClick = onNext) {
            Icon(
                Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = stringResource(R.string.nm_mosaic_next),
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/** A view's heading: one bold line and a grey caption, on the page's 20 dp margin. */
@Composable
fun MosaicHeading(title: String, caption: String?, modifier: Modifier = Modifier, trailing: (@Composable () -> Unit)? = null) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = modifier.fillMaxWidth().padding(start = 20.dp, end = 16.dp, top = 8.dp)) {
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = 21.sp, lineHeight = 27.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurface)
            if (caption != null) {
                Spacer(Modifier.size(2.dp))
                Text(caption, fontSize = 13.sp, lineHeight = 18.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        trailing?.invoke()
    }
}

/** The big count under a heart: "18 days recorded", with the basis of the count below it. */
@Composable
fun MosaicStat(count: Int, label: String, caption: String?, modifier: Modifier = Modifier) {
    Column(modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp)) {
        Row(verticalAlignment = Alignment.Bottom) {
            Text(count.toString(), fontSize = 32.sp, lineHeight = 36.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurface)
            Spacer(Modifier.width(6.dp))
            Text(label, fontSize = 15.sp, lineHeight = 22.sp, color = MaterialTheme.colorScheme.onSurface, modifier = Modifier.padding(bottom = 4.dp))
        }
        if (caption != null) {
            Text(caption, fontSize = 12.5.sp, lineHeight = 17.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** A pill chip in the app's manner (the avatar studio's style row): ink when chosen, grey otherwise. */
@Composable
fun MosaicChip(label: String, selected: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Surface(
        onClick = onClick,
        shape = CircleShape,
        color = if (selected) MaterialTheme.colorScheme.onSurface else MuseTones.fill,
        contentColor = if (selected) MaterialTheme.colorScheme.surface else MaterialTheme.colorScheme.onSurface,
        modifier = modifier.heightIn(min = 36.dp),
    ) {
        Text(
            label,
            fontSize = 13.sp,
            fontWeight = FontWeight.Medium,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 9.dp),
        )
    }
}

/**
 * The selected day under a heart or a calendar: its date, what it holds, and the way in. The
 * row itself is the button, so it is never smaller than a finger.
 */
@Composable
fun MosaicDayPreview(
    date: LocalDate,
    summary: DaySummary,
    today: LocalDate,
    store: MosaicStore,
    formats: MosaicFormats,
    onOpen: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val status = when {
        date.isAfter(today) -> stringResource(R.string.nm_mosaic_not_yet)
        !summary.recorded -> stringResource(R.string.nm_mosaic_no_record)
        summary.preview != null -> summary.preview
        else -> pluralStringResource(R.plurals.nm_mosaic_entries, summary.entryCount, summary.entryCount)
    }
    Surface(
        onClick = onOpen,
        shape = RoundedCornerShape(14.dp),
        color = MuseTones.fill,
        modifier = modifier.fillMaxWidth().padding(horizontal = 16.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(12.dp)) {
            val cover = summary.cover
            if (cover != null) {
                MosaicPhoto(cover, store, 44.dp, Modifier.size(44.dp).clip(CloudShape))
                Spacer(Modifier.width(12.dp))
            }
            Column(Modifier.weight(1f)) {
                Text(
                    formats.day.format(date),
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Text(
                    status,
                    fontSize = 13.sp,
                    lineHeight = 18.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Text(
                stringResource(R.string.nm_mosaic_open_day),
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium,
                color = MuseTones.action,
                modifier = Modifier.padding(start = 8.dp),
            )
        }
    }
}
