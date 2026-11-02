package io.github.nanomuse.ui.mosaic

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.MediaStore
import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.PhotoCamera
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.min
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.withStarted
import com.openminis.app.R
import com.openminis.app.service.SessionActivityTracker
import com.openminis.app.ui.chat.createCameraOutputUri
import com.openminis.app.ui.components.FullscreenImageViewer
import com.openminis.app.ui.theme.ChatColors
import io.github.nanomuse.mosaic.MosaicCrop
import io.github.nanomuse.mosaic.MosaicDraft
import io.github.nanomuse.mosaic.MosaicPhotoImport
import io.github.nanomuse.mosaic.MosaicSaveException
import io.github.nanomuse.mosaic.MosaicShape
import io.github.nanomuse.mosaic.MosaicStore
import io.github.nanomuse.ui.home.MuseTones
import io.github.nanomuse.ui.muse.MuseRow
import io.github.nanomuse.ui.muse.MuseTopAppBar
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.job
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.File
import java.time.LocalDate
import java.util.UUID

/** The editor's route; `day` is an epoch day, `habit`, `entry` and `draft` are optional ids. */
const val ROUTE_MOSAIC_EDIT = "nanomuse/mosaic/edit?day={day}&habit={habit}&entry={entry}&source={source}&draft={draft}"

/** Where the editor starts: straight in the camera or the picker, in the text field, or nowhere in particular. */
enum class MosaicEditSource { NONE, CAMERA, ALBUM, TEXT }

fun mosaicEditRoute(
    day: Long,
    habitId: String? = null,
    entryId: String? = null,
    source: MosaicEditSource = MosaicEditSource.NONE,
    draftId: String? = null,
): String = buildString {
    append("nanomuse/mosaic/edit?day=").append(day)
    if (habitId != null) append("&habit=").append(Uri.encode(habitId))
    if (entryId != null) append("&entry=").append(Uri.encode(entryId))
    append("&source=").append(source.name)
    if (draftId != null) append("&draft=").append(Uri.encode(draftId))
}

/**
 * One record, new or existing. The text field is ready at once; a photo imports in the background
 * and its shape and crop sit behind "Shape and crop". Every change goes to a draft within half a
 * second, so a call, a rotation or the system reclaiming the app loses nothing; the draft becomes
 * a record only when Save succeeds, and a failure keeps the editor as it was.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MosaicEditorScreen(
    day: Long,
    habitId: String?,
    entryId: String?,
    source: MosaicEditSource,
    onClose: () -> Unit,
    /** A kept draft opened from the day page's "Continue": its own id, which may differ from the target's after a date change. */
    draftKey: String? = null,
) {
    val context = LocalContext.current
    val store = remember { MosaicStore.get(context) }
    val formats = rememberMosaicFormats()
    val coroutines = rememberCoroutineScope()
    val today = rememberToday()
    val lifecycleOwner = LocalLifecycleOwner.current

    var draft by remember { mutableStateOf<MosaicDraft?>(null) }
    var habitTitle by remember { mutableStateOf<String?>(null) }
    var archivedFile by remember { mutableStateOf<File?>(null) }
    // A draft found on disk is already the person's; leaving asks whether to keep it.
    var restored by remember { mutableStateOf(false) }
    var dirty by remember { mutableStateOf(false) }
    var importing by remember { mutableStateOf(false) }
    var photoError by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    var isRedating by remember { mutableStateOf(false) }
    var autosaveJob by remember { mutableStateOf<kotlinx.coroutines.Job?>(null) }
    var error by remember { mutableStateOf<MosaicSaveException.Reason?>(null) }
    var adjusting by remember { mutableStateOf(false) }
    var leaving by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    var pickingDate by remember { mutableStateOf(false) }
    var moodMenu by remember { mutableStateOf(false) }
    // The mood the record already has; the draft itself holds only a mood the person chose here.
    var recordMood by remember { mutableStateOf<Int?>(null) }
    // When an existing record was written, for the title; a new one has no time yet.
    var recordedAt by remember { mutableStateOf<String?>(null) }
    // The photo full screen in its own proportions, to read back a page of homework or notes.
    var viewingPhoto by remember { mutableStateOf(false) }
    val textFocus = remember { FocusRequester() }

    LaunchedEffect(Unit) {
        val id = draftKey ?: MosaicStore.draftId(day, habitId, entryId)
        val row = entryId?.let { store.entryRow(it) }
        val habit = habitId?.let { store.habit(it) }
        val found = store.draft(id)
        restored = found != null
        habitTitle = habit?.title ?: row?.entry?.habitTitle
        recordedAt = row?.entry?.let(formats::recordedAt)
        recordMood = row?.entry?.mood
        archivedFile = row?.mediaPath?.let(store::mediaFile)
        draft = found ?: if (row != null) {
            val e = row.entry
            MosaicDraft(
                id = id, day = e.day, habitId = e.habitId, entryId = e.id, text = e.text,
                mediaId = e.mediaId, stagedPath = null, shape = e.shape,
                focusX = e.focusX, focusY = e.focusY, zoom = e.zoom,
                markDone = e.habitId?.let { store.habitDone(it, e.day) } ?: false,
                mood = null, mutationId = e.mutationId, updatedAt = System.currentTimeMillis(),
            )
        } else {
            MosaicDraft(
                id = id, day = day, habitId = habitId, entryId = null, text = "",
                mediaId = null, stagedPath = null, shape = habit?.shape ?: MosaicShape.ROUNDED.id,
                focusX = MosaicCrop.DEFAULT_FOCUS_X, focusY = MosaicCrop.DEFAULT_FOCUS_Y, zoom = 1f,
                markDone = habit != null, mood = null,
                mutationId = UUID.randomUUID().toString(), updatedAt = System.currentTimeMillis(),
            )
        }
    }
    // The draft follows every change, half a second after the last one.
    LaunchedEffect(draft, dirty, saving, isRedating) {
        if (saving || isRedating) return@LaunchedEffect
        autosaveJob = coroutineContext.job
        val current = draft ?: return@LaunchedEffect
        if (!dirty) return@LaunchedEffect
        delay(DRAFT_DELAY_MS)
        if (saving) return@LaunchedEffect
        try {
            store.putDraft(current.copy(updatedAt = System.currentTimeMillis()))
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // A full disk or a busy database: the next change tries again, and Save reports for itself.
        }
    }

    fun update(change: (MosaicDraft) -> MosaicDraft) {
        if (saving || isRedating) return
        draft = draft?.let(change)
        dirty = true
    }

    fun importPhoto(uri: Uri, cleanup: File? = null) {
        importing = true
        photoError = false
        coroutines.launch {
            try {
                val staged = MosaicPhotoImport.stage(context, uri, store.draftsDir)
                val previous = draft?.stagedPath
                update { it.copy(stagedPath = staged.path, focusX = MosaicCrop.DEFAULT_FOCUS_X, focusY = MosaicCrop.DEFAULT_FOCUS_Y, zoom = 1f) }
                previous?.let { File(it).delete() }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                photoError = true
            } finally {
                importing = false
                cleanup?.delete()
            }
        }
    }

    // The camera as the chat composer drives it: our own file, and the file (not the result code) says whether a photo came back.
    var pendingCamera by rememberSaveable { mutableStateOf<String?>(null) }
    val cameraLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        SessionActivityTracker.setCameraSuppressActive(false)
        val file = pendingCamera?.let(::File)
        pendingCamera = null
        if (file != null && file.exists() && file.length() > 0) importPhoto(Uri.fromFile(file), cleanup = file) else file?.delete()
    }
    fun launchCamera() {
        val (uri, file) = createCameraOutputUri(context)
        pendingCamera = file.absolutePath
        val intent = Intent(MediaStore.ACTION_IMAGE_CAPTURE).apply {
            putExtra(MediaStore.EXTRA_OUTPUT, uri)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        SessionActivityTracker.setCameraSuppressActive(true)
        runCatching { cameraLauncher.launch(intent) }.onFailure {
            SessionActivityTracker.setCameraSuppressActive(false)
            pendingCamera = null
            file.delete()
            Toast.makeText(context, R.string.nm_mosaic_camera_unavailable, Toast.LENGTH_SHORT).show()
        }
    }
    val permissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) launchCamera() else Toast.makeText(context, R.string.nm_mosaic_camera_denied, Toast.LENGTH_SHORT).show()
    }
    fun takePhoto() {
        val granted = ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
        if (granted) launchCamera() else permissionLauncher.launch(Manifest.permission.CAMERA)
    }
    val albumLauncher = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) importPhoto(uri)
    }
    fun pickPhoto() = albumLauncher.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))

    // The way in the person tapped on the day page, once; a restored draft that has a photo skips it.
    var started by rememberSaveable { mutableStateOf(false) }
    val loaded = draft != null
    LaunchedEffect(loaded) {
        val current = draft ?: return@LaunchedEffect
        if (started) return@LaunchedEffect
        started = true
        val hasPhoto = current.stagedPath != null || current.mediaId != null
        when (source) {
            MosaicEditSource.CAMERA -> if (!hasPhoto) takePhoto()
            MosaicEditSource.ALBUM -> if (!hasPhoto) pickPhoto()
            MosaicEditSource.TEXT -> runCatching { textFocus.requestFocus() }
            MosaicEditSource.NONE -> Unit
        }
    }

    fun leave() {
        if (saving || isRedating) return
        if (dirty || restored) leaving = true else onClose()
    }
    // Back is held while a save runs: popping here would leave the save to close whatever is underneath.
    BackHandler { if (!saving && !isRedating) leave() }

    fun save() {
        val current = draft ?: return
        if (saving || isRedating) return
        saving = true
        error = null
        coroutines.launch {
            try {
                autosaveJob?.cancelAndJoin()
                val saved = store.save(current, LocalDate.now())
                MosaicUi.showDay.value = saved?.day ?: current.day
                Toast.makeText(context, if (saved == null) R.string.nm_mosaic_marked_done else R.string.nm_mosaic_saved, Toast.LENGTH_SHORT).show()
                // A save that ends while the app is in the background closes when the person is back.
                lifecycleOwner.withStarted { onClose() }
            } catch (e: MosaicSaveException) {
                if (e.reason == MosaicSaveException.Reason.PHOTO_MISSING) draft = draft?.copy(stagedPath = null)
                error = e.reason
                saving = false
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                error = MosaicSaveException.Reason.DATABASE
                saving = false
            }
        }
    }

    val current = draft
    val date = LocalDate.ofEpochDay(current?.day ?: day)
    Scaffold(
        containerColor = ChatColors.background,
        topBar = {
            MuseTopAppBar(
                title = {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(stringResource(if (entryId == null) R.string.nm_mosaic_editor_title else R.string.nm_mosaic_editor_title_edit))
                        Text(
                            formats.monthDay.format(date) + (habitTitle?.let { " · $it" } ?: "") + (recordedAt?.let { " · $it" } ?: ""),
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Normal,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                },
                navigationIcon = {
                    TextButton(onClick = { leave() }, enabled = !saving && !isRedating) {
                        Text(stringResource(android.R.string.cancel), color = MaterialTheme.colorScheme.onSurface)
                    }
                },
                disc = false,
            )
        },
    ) { padding ->
        if (current == null) return@Scaffold
        val photo = current.stagedPath?.let(::File) ?: archivedFile.takeIf { current.mediaId != null }
        Column(
            Modifier
                .padding(padding)
                .fillMaxSize()
                .imePadding()
                .verticalScroll(rememberScrollState())
                .padding(bottom = 24.dp),
        ) {
            BoxWithConstraints(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp), contentAlignment = Alignment.Center) {
                val side = min(maxWidth, 320.dp)
                val sidePx = with(LocalDensity.current) { side.roundToPx() }
                if (photo != null) {
                    val image = rememberMosaicBitmap(photo, sidePx * 2)
                    // Every record's photo is drawn in the cloud, so the crop is set in it too.
                    // Outside cropping, a tap opens the whole photo.
                    val viewLabel = stringResource(R.string.nm_mosaic_photo_view)
                    Canvas(
                        Modifier
                            .size(side)
                            .clip(CloudShape)
                            .background(MuseTones.fill)
                            .then(if (adjusting) Modifier else Modifier.clickable(onClickLabel = viewLabel) { viewingPhoto = true })
                            .pointerInput(adjusting, image) {
                                val bitmap = image ?: return@pointerInput
                                if (!adjusting) return@pointerInput
                                detectTransformGestures { _, pan, gestureZoom, _ ->
                                    update { d ->
                                        val z = (d.zoom * gestureZoom).coerceIn(1f, MosaicCrop.MAX_ZOOM)
                                        val (fx, fy) = MosaicCrop.drag(
                                            bitmap.width, bitmap.height, size.width.toFloat(), size.height.toFloat(),
                                            d.focusX, d.focusY, z, pan.x, pan.y,
                                        )
                                        d.copy(focusX = fx, focusY = fy, zoom = z)
                                    }
                                }
                            },
                    ) {
                        if (image != null) drawCropped(image, current.focusX, current.focusY, current.zoom)
                    }
                } else {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.Center,
                        modifier = Modifier.size(side).clip(RoundedCornerShape(24.dp)).background(MuseTones.fill).padding(20.dp),
                    ) {
                        if (importing) {
                            CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Spacer(Modifier.height(10.dp))
                            Text(stringResource(R.string.nm_mosaic_photo_importing), fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        } else {
                            Text(
                                stringResource(if (photoError) R.string.nm_mosaic_photo_failed else R.string.nm_mosaic_photo_hint),
                                fontSize = 13.sp,
                                lineHeight = 18.sp,
                                color = if (photoError) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                                textAlign = TextAlign.Center,
                            )
                            Spacer(Modifier.height(14.dp))
                            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                PhotoButton(Icons.Outlined.PhotoCamera, stringResource(R.string.nm_mosaic_action_camera)) { takePhoto() }
                                PhotoButton(Icons.Outlined.Image, stringResource(R.string.nm_mosaic_action_album)) { pickPhoto() }
                            }
                        }
                    }
                }
            }

            if (photo != null) {
                Row(
                    horizontalArrangement = Arrangement.Center,
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp),
                ) {
                    TextButton(onClick = { pickPhoto() }, enabled = !importing && !saving && !isRedating) { Text(stringResource(R.string.nm_mosaic_photo_replace)) }
                    TextButton(onClick = { takePhoto() }, enabled = !importing && !saving && !isRedating) { Text(stringResource(R.string.nm_mosaic_action_camera)) }
                    TextButton(onClick = {
                        val previous = current.stagedPath
                        update { it.copy(stagedPath = null, mediaId = null) }
                        previous?.let { File(it).delete() }
                    }) { Text(stringResource(R.string.nm_mosaic_photo_remove)) }
                }
                if (photoError) {
                    Text(
                        stringResource(R.string.nm_mosaic_photo_failed),
                        fontSize = 13.sp,
                        color = MaterialTheme.colorScheme.error,
                        modifier = Modifier.padding(horizontal = 20.dp),
                    )
                }
            }

            // Crop: folded by default, since most photos sit well in the cloud as they are.
            if (photo != null) {
                MuseRow(
                    title = stringResource(R.string.nm_mosaic_adjust),
                    onClick = { adjusting = !adjusting },
                    chevron = !adjusting,
                )
                if (adjusting) {
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(start = 20.dp, end = 8.dp, top = 4.dp)) {
                        Text(
                            stringResource(R.string.nm_mosaic_crop_hint),
                            fontSize = 12.5.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.weight(1f),
                        )
                        TextButton(onClick = {
                            update { it.copy(focusX = MosaicCrop.DEFAULT_FOCUS_X, focusY = MosaicCrop.DEFAULT_FOCUS_Y, zoom = 1f) }
                        }) { Text(stringResource(R.string.nm_mosaic_crop_reset)) }
                    }
                }
            }

            Spacer(Modifier.height(10.dp))
            Text(
                stringResource(R.string.nm_mosaic_text_label),
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.padding(horizontal = 20.dp),
            )
            Spacer(Modifier.height(6.dp))
            OutlinedTextField(
                enabled = !saving && !isRedating,
                value = current.text,
                onValueChange = { text -> update { it.copy(text = text.take(TEXT_MAX)) } },
                placeholder = { Text(stringResource(R.string.nm_mosaic_text_hint), color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f)) },
                minLines = 3,
                maxLines = 8,
                shape = RoundedCornerShape(16.dp),
                colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = MuseTones.action, unfocusedBorderColor = MuseTones.hairline),
                supportingText = {
                    Text(
                        stringResource(R.string.nm_mosaic_text_count, current.text.length, TEXT_MAX),
                        textAlign = TextAlign.End,
                        modifier = Modifier.fillMaxWidth(),
                    )
                },
                modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp).focusRequester(textFocus),
            )

            val title = habitTitle
            if (current.habitId != null && title != null) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .toggleable(value = current.markDone, role = Role.Checkbox) { checked -> update { it.copy(markDone = checked) } }
                        .heightIn(min = 52.dp)
                        .padding(horizontal = 8.dp),
                ) {
                    Checkbox(
                        checked = current.markDone,
                        onCheckedChange = null,
                        colors = CheckboxDefaults.colors(checkedColor = MuseTones.action),
                    )
                    Spacer(Modifier.width(4.dp))
                    Text(stringResource(R.string.nm_mosaic_mark_habit, title), fontSize = 15.sp, color = MaterialTheme.colorScheme.onSurface)
                }
            }

            Box {
                val shownMood = when (current.mood) {
                    null -> recordMood
                    MosaicStore.MOOD_CLEARED -> null
                    else -> current.mood
                }
                MuseRow(
                    title = stringResource(R.string.nm_mosaic_mood),
                    value = stringResource(shownMood?.let { moodLabel(it) } ?: R.string.nm_mosaic_mood_none),
                    onClick = { if (!saving && !isRedating) moodMenu = true },
                )
                DropdownMenu(expanded = moodMenu, onDismissRequest = { moodMenu = false }) {
                    (1..5).forEach { level ->
                        DropdownMenuItem(
                            text = { Text(stringResource(moodLabel(level))) },
                            // the energy the record will show for it
                            trailingIcon = { MosaicEnergy(level) },
                            onClick = {
                                moodMenu = false
                                update { it.copy(mood = level) }
                            },
                        )
                    }
                    DropdownMenuItem(text = { Text(stringResource(R.string.nm_mosaic_mood_none)) }, onClick = {
                        moodMenu = false
                        update { it.copy(mood = MosaicStore.MOOD_CLEARED) }
                    })
                }
            }
            MuseRow(
                title = stringResource(R.string.nm_mosaic_date),
                value = formats.day.format(date),
                onClick = { if (!saving && !isRedating) pickingDate = true },
            )

            error?.let { reason ->
                Text(
                    stringResource(
                        when (reason) {
                            MosaicSaveException.Reason.EMPTY -> R.string.nm_mosaic_err_empty
                            MosaicSaveException.Reason.FUTURE -> R.string.nm_mosaic_err_future
                            MosaicSaveException.Reason.PHOTO_MISSING -> R.string.nm_mosaic_err_photo_missing
                            MosaicSaveException.Reason.STORAGE -> R.string.nm_mosaic_err_storage
                            MosaicSaveException.Reason.DATABASE -> R.string.nm_mosaic_err_database
                        },
                    ),
                    fontSize = 13.sp,
                    lineHeight = 18.sp,
                    color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 6.dp),
                )
            }

            Spacer(Modifier.height(14.dp))
            val canSave = !saving && !isRedating && !importing &&
                (current.text.isNotBlank() || photo != null || (current.markDone && current.habitId != null && current.entryId == null))
            Button(
                onClick = { save() },
                enabled = canSave,
                shape = CircleShape,
                colors = ButtonDefaults.buttonColors(
                    containerColor = MuseTones.action,
                    contentColor = Color.White,
                    disabledContainerColor = MuseTones.action.copy(alpha = 0.5f),
                    disabledContentColor = Color.White,
                ),
                modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp).height(50.dp),
            ) {
                if (saving) {
                    CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = Color.White)
                } else {
                    Icon(Icons.Filled.Check, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.nm_mosaic_save_entry), fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                }
            }
            Text(
                stringResource(R.string.nm_mosaic_saved_locally),
                fontSize = 12.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            )
            if (entryId != null) {
                TextButton(
                    onClick = { confirmDelete = true },
                    enabled = !saving && !isRedating,
                    modifier = Modifier.align(Alignment.CenterHorizontally).padding(top = 8.dp),
                ) { Text(stringResource(R.string.nm_mosaic_delete_entry), color = MaterialTheme.colorScheme.error) }
            }
        }
    }

    val fullPhoto = current?.let { c -> c.stagedPath?.let(::File) ?: archivedFile.takeIf { c.mediaId != null } }
    if (viewingPhoto && fullPhoto != null) {
        FullscreenImageViewer(model = fullPhoto, onDismiss = { viewingPhoto = false })
    }
    if (pickingDate && current != null) {
        MosaicDatePicker(
            initial = date,
            today = today,
            latest = today,
            onPick = { picked ->
                val newDay = picked.toEpochDay()
                val before = draft
                if (before != null && newDay != before.day && !saving && !isRedating) {
                    coroutines.launch {
                        isRedating = true
                        try {
                            // 先等待旧自动保存退出，再迁移主键，避免旧草稿被重新写回。
                            autosaveJob?.cancelAndJoin()
                            val moved = store.redate(before, newDay)
                            draft = moved
                            dirty = true
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: Exception) {
                            error = MosaicSaveException.Reason.DATABASE
                        } finally { isRedating = false }
                    }
                }
            },
            onDismiss = { pickingDate = false },
        )
    }
    if (leaving) {
        AlertDialog(
            onDismissRequest = { leaving = false },
            title = { Text(stringResource(R.string.nm_mosaic_leave_title)) },
            text = { Text(stringResource(R.string.nm_mosaic_leave_body)) },
            confirmButton = {
                TextButton(onClick = {
                    leaving = false
                    val keep = draft
                    saving = true
                    coroutines.launch {
                        autosaveJob?.cancelAndJoin()
                        if (keep != null && dirty) runStoreCall(context) { store.putDraft(keep.copy(updatedAt = System.currentTimeMillis())) }
                        onClose()
                    }
                }) { Text(stringResource(R.string.nm_mosaic_keep)) }
            },
            dismissButton = {
                TextButton(onClick = {
                    leaving = false
                    val drop = draft
                    saving = true // stops the pending autosave from writing the draft back
                    coroutines.launch {
                        autosaveJob?.cancelAndJoin()
                        if (drop != null) runStoreCall(context) { store.discardDraft(drop) }
                        onClose()
                    }
                }) { Text(stringResource(R.string.nm_mosaic_discard), color = MaterialTheme.colorScheme.error) }
            },
        )
    }
    if (confirmDelete && entryId != null) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text(stringResource(R.string.nm_mosaic_delete_title)) },
            text = { Text(stringResource(R.string.nm_mosaic_delete_body)) },
            confirmButton = {
                TextButton(onClick = {
                    confirmDelete = false
                    saving = true
                    coroutines.launch {
                        // The route's day is where the record is saved; an unsaved date change does not count.
                        if (runStoreCall(context) { store.delete(entryId) }) {
                            MosaicUi.showDay.value = day
                            MosaicUi.deleted.value = entryId to day
                        }
                        onClose()
                    }
                }) { Text(stringResource(R.string.nm_mosaic_menu_delete), color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text(stringResource(android.R.string.cancel)) } },
        )
    }
}

@Composable
private fun PhotoButton(icon: ImageVector, label: String, onClick: () -> Unit) {
    Surface(onClick = onClick, shape = CircleShape, color = MuseTones.surface, modifier = Modifier.height(44.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(horizontal = 16.dp)) {
            Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.onSurface, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(6.dp))
            Text(label, fontSize = 14.sp, fontWeight = FontWeight.Medium, color = MaterialTheme.colorScheme.onSurface)
        }
    }
}

private fun moodLabel(level: Int): Int = when (level) {
    1 -> R.string.nm_mosaic_mood_1
    2 -> R.string.nm_mosaic_mood_2
    3 -> R.string.nm_mosaic_mood_3
    4 -> R.string.nm_mosaic_mood_4
    else -> R.string.nm_mosaic_mood_5
}

private const val TEXT_MAX = 2000
private const val DRAFT_DELAY_MS = 400L
