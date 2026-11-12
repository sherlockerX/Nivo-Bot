package io.github.nanomuse.ui.focus

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AddPhotoAlternate
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import com.openminis.app.R
import io.github.nanomuse.focus.FocusBackdropStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/** 本地背景选择器：只有用户点击导入才请求系统选择文件。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun FocusBackdropPicker(store: FocusBackdropStore, onClose: () -> Unit, onSelected: () -> Unit) {
    val scope = rememberCoroutineScope()
    var rows by remember { mutableStateOf(emptyList<FocusBackdropStore.Backdrop>()) }
    var selected by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf<String?>(null) }
    suspend fun reload() { rows = store.list(); selected = store.selected() }
    fun perform(action: suspend () -> Unit) {
        if (busy) return
        busy = true; failed = false
        scope.launch {
            try { action(); reload(); onSelected() }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { failed = true }
            finally { busy = false }
        }
    }
    LaunchedEffect(store) { try { reload() } catch (_: Exception) { failed = true } }
    val importer = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) perform { val row = store.importBackground(uri); store.select(row.id) }
    }
    ModalBottomSheet(onDismissRequest = { if (!busy) onClose() }) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text(stringResource(R.string.nm_focus_backgrounds), style = MaterialTheme.typography.headlineSmall)
            Text(stringResource(R.string.nm_focus_background_hint), style = MaterialTheme.typography.bodyMedium)
            OutlinedButton(onClick = { importer.launch(arrayOf("image/*")) }, enabled = !busy && rows.size < FocusBackdropStore.MAX_BACKGROUNDS,
                modifier = Modifier.fillMaxWidth()) {
                Icon(Icons.Outlined.AddPhotoAlternate, null); Spacer(Modifier.width(8.dp)); Text(stringResource(R.string.nm_focus_import_background))
            }
            if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            if (failed) Text(stringResource(R.string.nm_focus_background_error), color = MaterialTheme.colorScheme.error)
            LazyVerticalGrid(columns = GridCells.Adaptive(130.dp), modifier = Modifier.fillMaxWidth().heightIn(max = 390.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                item { BackdropTile(selected == null, stringResource(R.string.nm_focus_vector_background), { perform { store.select(null) } }) {
                    FocusLandscape(Modifier.fillMaxSize())
                } }
                items(rows, key = { it.id }) { row ->
                    Box { BackdropTile(selected == row.id, stringResource(R.string.nm_focus_local_background), { perform { store.select(row.id) } }) {
                        AsyncImage(store.file(row.id), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                    }
                        IconButton(onClick = { if (!busy) deleting = row.id }, modifier = Modifier.align(Alignment.TopEnd)) {
                            Icon(Icons.Outlined.DeleteOutline, stringResource(R.string.nm_focus_delete_background), tint = Color.White)
                        }
                    }
                }
            }
            TextButton(onClick = onClose, enabled = !busy, modifier = Modifier.align(Alignment.End)) { Text(stringResource(R.string.nm_todo_close)) }
        }
    }
    deleting?.let { id -> AlertDialog(onDismissRequest = { deleting = null },
        title = { Text(stringResource(R.string.nm_focus_delete_background)) }, text = { Text(stringResource(R.string.nm_focus_delete_background_hint)) },
        confirmButton = { TextButton(onClick = { deleting = null; perform { store.delete(id) } }) { Text(stringResource(R.string.nm_focus_delete_background)) } },
        dismissButton = { TextButton(onClick = { deleting = null }) { Text(stringResource(android.R.string.cancel)) } }) }
}

/** 每张背景保留文字名称和选中标记，不靠颜色表达选择。 */
@Composable
private fun BackdropTile(selected: Boolean, label: String, onClick: () -> Unit, content: @Composable () -> Unit) {
    Surface(onClick = onClick, shape = RoundedCornerShape(18.dp), border = BorderStroke(if (selected) 3.dp else 1.dp,
        if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant)) {
        Column { Box(Modifier.fillMaxWidth().height(150.dp).clip(RoundedCornerShape(16.dp))) {
            content()
            if (selected) Icon(Icons.Outlined.CheckCircle, null, Modifier.align(Alignment.BottomEnd).padding(8.dp), tint = Color.White)
        }
            Text(label, Modifier.padding(10.dp), style = MaterialTheme.typography.labelLarge)
        }
    }
}
