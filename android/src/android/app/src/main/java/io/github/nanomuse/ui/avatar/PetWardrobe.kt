package io.github.nanomuse.ui.avatar

import android.widget.Toast
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.painter.BitmapPainter
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openminis.app.R
import io.github.nanomuse.avatar.AvatarMotion
import io.github.nanomuse.avatar.AvatarStore
import io.github.nanomuse.avatar.AvatarStudio
import io.github.nanomuse.avatar.AvatarWardrobe
import io.github.nanomuse.ui.home.MuseTones
import io.github.nanomuse.ui.home.avatarDiscColor
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Mosaic: "Your pets": the dragon and every face kept so far, worn again with a tap and no new
 * pictures. Long-press a kept one to let it go. Switching waits while poses or clips are still
 * being made, since those land on the face in use.
 */
@Composable
internal fun PetWardrobe(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val current by AvatarStore.current.collectAsState()
    val kept by AvatarWardrobe.pets.collectAsState()
    val poses by AvatarStudio.moodProgress.collectAsState()
    val clips by AvatarMotion.progress.collectAsState()
    val busy = poses?.running == true || clips?.running == true
    var switching by remember { mutableStateOf(false) }
    var removing by remember { mutableStateOf<AvatarWardrobe.Pet?>(null) }
    val currentId = AvatarWardrobe.idOf(current)
    val busyText = stringResource(R.string.nm_pet_busy)
    val unnamed = stringResource(R.string.nm_pet_unnamed)
    fun label(prompt: String): String {
        val words = prompt.trim()
        return when {
            words.isEmpty() -> unnamed
            words.length > 6 -> words.take(6) + "…"
            else -> words
        }
    }

    fun wear(id: String) {
        if (id == currentId || switching) return
        if (busy) {
            Toast.makeText(context, busyText, Toast.LENGTH_SHORT).show()
            return
        }
        switching = true
        scope.launch {
            withContext(Dispatchers.IO) { runCatching { AvatarWardrobe.wear(id) } }
            switching = false
        }
    }

    Column(modifier) {
        Text(stringResource(R.string.nm_pet_title), fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurface)
        Spacer(Modifier.height(4.dp))
        Text(stringResource(R.string.nm_pet_hint), fontSize = 13.sp, lineHeight = 18.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.height(10.dp))
        LazyRow(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            item(key = AvatarWardrobe.DRAGON) {
                PetChip(painterResource(R.drawable.nm_avatar_idle), stringResource(R.string.nm_pet_dragon), worn = currentId == AvatarWardrobe.DRAGON, onClick = { wear(AvatarWardrobe.DRAGON) })
            }
            // The face in use before it has ever been kept: shown, and kept the first time it is replaced.
            val unkept = current?.takeIf { kept.none { pet -> pet.id == currentId } }
            if (unkept != null) {
                item(key = currentId) {
                    PetChip(remember(unkept.base) { BitmapPainter(unkept.base) }, label(unkept.prompt), worn = true, onClick = {})
                }
            }
            items(kept, key = { it.id }) { pet ->
                val worn = pet.id == currentId
                PetChip(
                    remember(pet.face) { BitmapPainter(pet.face) },
                    label(pet.prompt),
                    worn = worn,
                    onClick = { wear(pet.id) },
                    onLongClick = if (worn) null else ({ removing = pet }),
                )
            }
        }
    }

    removing?.let { pet ->
        AlertDialog(
            onDismissRequest = { removing = null },
            title = { Text(stringResource(R.string.nm_pet_remove_title)) },
            text = { Text(stringResource(R.string.nm_pet_remove_body)) },
            confirmButton = {
                TextButton(onClick = {
                    removing = null
                    scope.launch { withContext(Dispatchers.IO) { AvatarWardrobe.remove(pet.id) } }
                }) { Text(stringResource(R.string.nm_pet_remove), color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { removing = null }) { Text(stringResource(android.R.string.cancel)) } },
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun PetChip(painter: Painter, label: String, worn: Boolean, onClick: () -> Unit, onLongClick: (() -> Unit)? = null) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.width(72.dp)) {
        Box(
            Modifier
                .size(64.dp)
                .clip(CircleShape)
                .background(avatarDiscColor())
                .then(if (worn) Modifier.border(3.dp, MuseTones.action, CircleShape) else Modifier)
                .combinedClickable(onClick = onClick, onLongClick = onLongClick),
        ) {
            Image(painter, contentDescription = label, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        }
        Spacer(Modifier.height(4.dp))
        Text(
            label,
            fontSize = 11.sp,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            color = if (worn) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}
