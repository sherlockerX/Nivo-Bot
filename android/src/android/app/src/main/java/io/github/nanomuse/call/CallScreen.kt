package io.github.nanomuse.call

import android.Manifest
import android.content.pm.PackageManager
import android.net.Uri
import android.os.SystemClock
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.CallEnd
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MicOff
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import com.openminis.app.R
import com.openminis.app.agent.SoulStore
import com.openminis.app.data.repository.ProviderRepository
import com.openminis.app.ui.chat.ChatViewModel
import com.openminis.app.ui.theme.ChatColors
import io.github.nanomuse.ui.avatar.AgentAvatarDisc
import io.github.nanomuse.ui.avatar.AgentMood
import io.github.nanomuse.ui.home.MuseTones
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import java.util.Locale

/** The call page's route; `session` is the chat the call talks in. */
const val ROUTE_CALL = "nanomuse/call?session={session}"

fun callRoute(sessionId: String): String = "nanomuse/call?session=" + Uri.encode(sessionId)

/**
 * A voice call with the agent, full screen: its face reacting to the call, what the person said
 * and what it is saying, and mute, hang up and loudspeaker. The call runs while the page is open
 * and ends with it. Without a Bailian key or the microphone it says what is missing instead.
 */
@Composable
fun CallScreen(
    sessionId: String,
    vm: ChatViewModel,
    providerRepository: ProviderRepository,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    var settings by remember { mutableStateOf(CallSettings.load(context)) }
    var editing by remember { mutableStateOf(false) }
    val apiKey = remember { bailianKey(providerRepository) }
    var micGranted by remember {
        mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED)
    }
    val askMic = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { micGranted = it }
    LaunchedEffect(Unit) {
        if (!micGranted) askMic.launch(Manifest.permission.RECORD_AUDIO)
    }

    // A new call whenever the settings change; leaving the page hangs up.
    val session = remember(apiKey, micGranted, settings) {
        if (apiKey != null && micGranted) CallSession(context.applicationContext, vm, sessionId, apiKey, settings) else null
    }
    DisposableEffect(session) {
        session?.start()
        onDispose { session?.hangUp() }
    }
    val view = LocalView.current
    DisposableEffect(Unit) {
        view.keepScreenOn = true
        onDispose { view.keepScreenOn = false }
    }
    BackHandler(onBack = onClose)

    // Stand-ins while there is no call (no key or no microphone), so every read below is unconditional.
    val noPhase = remember { MutableStateFlow(CallPhase.ENDED) }
    val noText = remember { MutableStateFlow("") }
    val noProblem = remember { MutableStateFlow<String?>(null) }
    val off = remember { MutableStateFlow(false) }
    val phase by (session?.phase ?: noPhase).collectAsState()
    val heard by (session?.heard ?: noText).collectAsState()
    val reply by (session?.reply ?: noText).collectAsState()
    val problem by (session?.problem ?: noProblem).collectAsState()
    val muted by (session?.muted ?: off).collectAsState()
    val speaker by (session?.speaker ?: off).collectAsState()
    val soul by SoulStore.cachedMetadata.collectAsState()

    var seconds by remember(session) { mutableLongStateOf(0L) }
    LaunchedEffect(session, phase == CallPhase.ENDED) {
        if (session == null || phase == CallPhase.ENDED) return@LaunchedEffect
        val start = SystemClock.elapsedRealtime() - seconds * 1_000L
        while (true) {
            seconds = (SystemClock.elapsedRealtime() - start) / 1_000L
            delay(1_000L)
        }
    }

    val status = stringResource(
        when (phase) {
            CallPhase.CONNECTING -> R.string.nm_call_connecting
            CallPhase.LISTENING -> R.string.nm_call_listening
            CallPhase.HEARING -> R.string.nm_call_hearing
            CallPhase.THINKING -> R.string.nm_call_thinking
            CallPhase.SPEAKING -> R.string.nm_call_speaking
            CallPhase.ENDED -> R.string.nm_call_ended
        },
    )
    val mood = when {
        problem != null && phase == CallPhase.ENDED -> AgentMood.ERROR
        phase == CallPhase.THINKING || phase == CallPhase.SPEAKING -> AgentMood.WORKING
        else -> AgentMood.IDLE
    }

    Surface(color = ChatColors.background, modifier = Modifier.fillMaxSize()) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxSize().systemBarsPadding()) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp)) {
                Spacer(Modifier.weight(1f))
                IconButton(onClick = { editing = true }) {
                    Icon(Icons.Outlined.Settings, contentDescription = stringResource(R.string.nm_call_settings), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            Spacer(Modifier.height(20.dp))
            AgentAvatarDisc(mood = mood, discSize = 132.dp)
            Spacer(Modifier.height(14.dp))
            Text(
                soul.name.trim().ifEmpty { stringResource(R.string.app_name) },
                fontSize = 22.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Spacer(Modifier.height(4.dp))
            // No call yet (no key or no microphone): the notice below says why, so no status here.
            Text(
                if (session != null) "$status · ${clock(seconds)}" else "",
                fontSize = 14.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(24.dp))
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 28.dp),
            ) {
                when {
                    apiKey == null -> Notice(stringResource(R.string.nm_call_no_key))
                    !micGranted -> {
                        Notice(stringResource(R.string.nm_call_need_mic))
                        TextButton(onClick = { askMic.launch(Manifest.permission.RECORD_AUDIO) }) {
                            Text(stringResource(R.string.nm_call_allow_mic), color = MuseTones.action)
                        }
                    }
                    else -> {
                        if (heard.isNotEmpty()) {
                            Text(heard, fontSize = 15.sp, lineHeight = 21.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center, maxLines = 4, overflow = TextOverflow.Ellipsis)
                        }
                        if (reply.isNotEmpty()) {
                            Text(reply, fontSize = 17.sp, lineHeight = 24.sp, color = MaterialTheme.colorScheme.onSurface, textAlign = TextAlign.Center)
                        }
                        problem?.let { Notice(it, error = true) }
                    }
                }
            }
            // A tool that needs the person's approval asks here too; without it the call would wait in silence.
            io.github.nanomuse.ui.guard.RiskApprovalHost(sessionId = vm.activeSessionId, onOpenSession = { onClose() })
            // Mosaic: speaking over the reply cuts it short; the button does the same without a word.
            if (phase == CallPhase.THINKING || phase == CallPhase.SPEAKING) {
                TextButton(onClick = { session?.interrupt() }) {
                    Text(stringResource(R.string.nm_call_interrupt), color = MuseTones.action, fontSize = 15.sp)
                }
            }
            Row(
                horizontalArrangement = Arrangement.SpaceEvenly,
                verticalAlignment = Alignment.Bottom,
                modifier = Modifier.fillMaxWidth().padding(top = 12.dp, bottom = 36.dp),
            ) {
                CallControl(
                    icon = if (muted) Icons.Filled.MicOff else Icons.Filled.Mic,
                    label = stringResource(if (muted) R.string.nm_call_unmute else R.string.nm_call_mute),
                    active = muted,
                    enabled = session != null,
                ) { session?.setMuted(!muted) }
                CallControl(
                    icon = Icons.Filled.CallEnd,
                    label = stringResource(R.string.nm_call_hang_up),
                    active = false,
                    hangUp = true,
                    onClick = onClose,
                )
                CallControl(
                    icon = Icons.AutoMirrored.Filled.VolumeUp,
                    label = stringResource(R.string.nm_call_speaker),
                    active = speaker,
                    enabled = session != null,
                ) { session?.setSpeaker(!speaker) }
            }
        }
    }

    if (editing) {
        CallSettingsDialog(
            initial = settings,
            onDismiss = { editing = false },
            onSave = { saved ->
                CallSettings.save(context, saved)
                settings = CallSettings.load(context)
                editing = false
            },
        )
    }
}

@Composable
private fun Notice(text: String, error: Boolean = false) {
    Text(
        text,
        fontSize = 14.sp,
        lineHeight = 20.sp,
        color = if (error) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
        textAlign = TextAlign.Center,
    )
}

@Composable
private fun CallControl(
    icon: ImageVector,
    label: String,
    active: Boolean,
    enabled: Boolean = true,
    hangUp: Boolean = false,
    onClick: () -> Unit,
) {
    val size = if (hangUp) 72.dp else 60.dp
    val container = when {
        hangUp -> HANG_UP_RED
        active -> MaterialTheme.colorScheme.onSurface
        else -> MuseTones.fill
    }
    val content = when {
        hangUp -> Color.White
        active -> MaterialTheme.colorScheme.surface
        else -> MaterialTheme.colorScheme.onSurface
    }
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Surface(onClick = onClick, enabled = enabled, shape = CircleShape, color = container, modifier = Modifier.size(size)) {
            Box(contentAlignment = Alignment.Center) {
                Icon(icon, contentDescription = label, tint = content.copy(alpha = if (enabled) 1f else 0.4f), modifier = Modifier.size(if (hangUp) 32.dp else 26.dp))
            }
        }
        Spacer(Modifier.height(8.dp))
        Text(label, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** The call's Bailian settings: address, models, voice and the pause that ends a turn. */
@Composable
private fun CallSettingsDialog(initial: CallSettings, onDismiss: () -> Unit, onSave: (CallSettings) -> Unit) {
    var endpoint by remember { mutableStateOf(initial.endpoint) }
    var asrModel by remember { mutableStateOf(initial.asrModel) }
    var ttsModel by remember { mutableStateOf(initial.ttsModel) }
    var voice by remember { mutableStateOf(initial.voice) }
    var silence by remember { mutableStateOf(initial.silenceMs.toString()) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.nm_call_settings)) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SettingField(stringResource(R.string.nm_call_endpoint), endpoint) { endpoint = it }
                Text(stringResource(R.string.nm_call_endpoint_hint), fontSize = 12.sp, lineHeight = 16.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                SettingField(stringResource(R.string.nm_call_asr_model), asrModel) { asrModel = it }
                SettingField(stringResource(R.string.nm_call_tts_model), ttsModel) { ttsModel = it }
                SettingField(stringResource(R.string.nm_call_voice), voice) { voice = it }
                SettingField(stringResource(R.string.nm_call_silence), silence, number = true) { silence = it.filter(Char::isDigit).take(4) }
            }
        },
        confirmButton = {
            TextButton(onClick = {
                onSave(
                    CallSettings(
                        endpoint = endpoint.ifBlank { CallSettings.DEFAULT_ENDPOINT },
                        asrModel = asrModel.ifBlank { CallSettings.DEFAULT_ASR_MODEL },
                        ttsModel = ttsModel.ifBlank { CallSettings.DEFAULT_TTS_MODEL },
                        voice = voice.ifBlank { CallSettings.DEFAULT_VOICE },
                        silenceMs = silence.toIntOrNull() ?: CallSettings.DEFAULT_SILENCE_MS,
                    ),
                )
            }) { Text(stringResource(android.R.string.ok)) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(android.R.string.cancel)) } },
    )
}

@Composable
private fun SettingField(label: String, value: String, number: Boolean = false, onChange: (String) -> Unit) {
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        label = { Text(label) },
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = if (number) KeyboardType.Number else KeyboardType.Uri),
        shape = RoundedCornerShape(14.dp),
        colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = MuseTones.action, unfocusedBorderColor = MuseTones.hairline),
        modifier = Modifier.fillMaxWidth(),
    )
}

private fun clock(seconds: Long): String =
    String.format(Locale.ROOT, "%02d:%02d", seconds / 60L, seconds % 60L)

private val HANG_UP_RED = Color(0xFFE5484D)
