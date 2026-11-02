package io.github.nanomuse.ui.chat

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.widget.Toast
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
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
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.layer.drawLayer
import androidx.compose.ui.graphics.rememberGraphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.FileProvider
import com.openminis.app.R
import com.openminis.app.agent.SoulStore
import com.openminis.app.ui.chat.StreamingMarkdownText
import com.openminis.app.ui.components.saveToGallery
import com.openminis.app.ui.theme.ChatColors
import com.openminis.app.ui.theme.MinisTheme
import io.github.nanomuse.avatar.AvatarStore
import io.github.nanomuse.ui.home.MuseTones
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.text.DateFormat
import java.util.Date

/**
 * Mosaic: a reply as a picture. The preview is the picture: the agent's face and name, the
 * question, the answer as the chat renders it, and an "AI generated" footer, always on white
 * so it reads the same wherever it is sent. Saved to Pictures/Nicholasx or handed to the
 * share sheet.
 */
@Composable
internal fun NmReplyShareDialog(question: String?, answer: String, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val layer = rememberGraphicsLayer()
    var working by remember { mutableStateOf(false) }
    val soul by SoulStore.cachedMetadata.collectAsState()
    val name = soul.name.trim().ifEmpty { stringResource(R.string.app_name) }
    val face by AvatarStore.current.collectAsState()
    val date = remember { DateFormat.getDateInstance(DateFormat.LONG).format(Date()) }

    fun withPicture(use: suspend (Bitmap) -> Unit) {
        if (working) return
        working = true
        scope.launch {
            try {
                // 超长分享卡先检查尺寸，避免一次分配过大的 Bitmap。
                check(layer.size.width.toLong() * layer.size.height <= 16_000_000L)
                val drawn = layer.toImageBitmap().asAndroidBitmap()
                // Mosaic: copying a long card out of GPU memory takes a while; not on the main thread.
                val picture = if (drawn.config == Bitmap.Config.HARDWARE) withContext(Dispatchers.Default) { drawn.copy(Bitmap.Config.ARGB_8888, false) } else drawn
                check(picture != null && picture.width > 0 && picture.height > 0)
                use(picture)
            } catch (error: Exception) {
                if (error is kotlinx.coroutines.CancellationException) throw error
                Toast.makeText(context, R.string.nm_reply_share_failed, Toast.LENGTH_SHORT).show()
            } finally { working = false }
        }
    }

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(color = ChatColors.secondaryBg, modifier = Modifier.fillMaxSize()) {
            Column(Modifier.fillMaxSize()) {
                Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = onDismiss) {
                        Icon(Icons.Default.Close, contentDescription = stringResource(R.string.nm_reply_share_close))
                    }
                    Text(stringResource(R.string.nm_reply_share_image), fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                }
                Box(
                    contentAlignment = Alignment.TopCenter,
                    modifier = Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(vertical = 12.dp),
                ) {
                    Box(
                        Modifier
                            .shadow(4.dp, RoundedCornerShape(6.dp))
                            .drawWithContent {
                                layer.record { this@drawWithContent.drawContent() }
                                drawLayer(layer)
                            },
                    ) {
                        MinisTheme(darkTheme = false) { ReplyCard(name, face?.base, date, question, answer) }
                    }
                }
                Row(
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
                ) {
                    OutlinedButton(
                        onClick = {
                            withPicture { picture ->
                                val saved = saveToGallery(context, picture)
                                Toast.makeText(
                                    context,
                                    if (saved) R.string.nm_reply_share_saved else R.string.nm_reply_share_failed,
                                    Toast.LENGTH_SHORT,
                                ).show()
                            }
                        },
                        enabled = !working,
                        modifier = Modifier.weight(1f),
                    ) { Text(stringResource(R.string.nm_reply_share_save)) }
                    Button(
                        onClick = { withPicture { picture -> sharePicture(context, picture) } },
                        enabled = !working,
                        colors = ButtonDefaults.buttonColors(containerColor = MuseTones.action, contentColor = Color.White),
                        modifier = Modifier.weight(1f),
                    ) { Text(stringResource(R.string.nm_reply_share)) }
                }
            }
        }
    }
}

@Composable
private fun ReplyCard(name: String, face: ImageBitmap?, date: String, question: String?, answer: String) {
    Column(Modifier.width(360.dp).background(ChatColors.background).padding(horizontal = 22.dp, vertical = 24.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            val faceModifier = Modifier.size(40.dp).clip(CircleShape).background(ChatColors.secondaryBg)
            if (face != null) {
                Image(face, contentDescription = null, contentScale = ContentScale.Crop, modifier = faceModifier)
            } else {
                Image(painterResource(R.drawable.nm_avatar_idle), contentDescription = null, contentScale = ContentScale.Crop, modifier = faceModifier)
            }
            Spacer(Modifier.width(10.dp))
            Column {
                Text(name, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = ChatColors.primaryText)
                Text(date, fontSize = 12.sp, color = ChatColors.secondaryText)
            }
        }
        if (!question.isNullOrBlank()) {
            Spacer(Modifier.height(18.dp))
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
                Text(
                    question.trim(),
                    fontSize = 15.sp,
                    lineHeight = 21.sp,
                    color = ChatColors.primaryText,
                    maxLines = 8,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier
                        .widthIn(max = 280.dp)
                        .clip(RoundedCornerShape(18.dp))
                        .background(ChatColors.secondaryBg)
                        .padding(horizontal = 14.dp, vertical = 9.dp),
                )
            }
        }
        Spacer(Modifier.height(14.dp))
        StreamingMarkdownText(content = answer, isStreaming = false)
        Spacer(Modifier.height(22.dp))
        HorizontalDivider(color = ChatColors.secondaryBg)
        Spacer(Modifier.height(10.dp))
        Text(
            "$name · ${stringResource(R.string.nm_reply_share_footer)}",
            fontSize = 11.sp,
            color = ChatColors.secondaryText,
            style = MaterialTheme.typography.bodySmall,
        )
    }
}

private suspend fun sharePicture(context: Context, picture: Bitmap) {
    val uri = runCatching {
        withContext(Dispatchers.IO) {
            val dir = File(context.cacheDir, "share").apply { mkdirs() }
            val file = File(dir, "nicholasx-reply-${System.currentTimeMillis()}.png")
            file.outputStream().use { picture.compress(Bitmap.CompressFormat.PNG, 100, it) }
            FileProvider.getUriForFile(context, context.packageName + ".fileprovider", file)
        }
    }.getOrNull()
    if (uri == null) {
        Toast.makeText(context, R.string.nm_reply_share_failed, Toast.LENGTH_SHORT).show()
        return
    }
    val send = Intent(Intent.ACTION_SEND).apply {
        type = "image/png"
        putExtra(Intent.EXTRA_STREAM, uri)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
    val chooser = Intent.createChooser(send, context.getString(R.string.nm_reply_share_image)).apply {
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
    runCatching { context.startActivity(chooser) }
}
