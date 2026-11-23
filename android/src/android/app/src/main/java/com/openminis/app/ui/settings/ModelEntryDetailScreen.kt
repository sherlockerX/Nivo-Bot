package com.openminis.app.ui.settings

// nanoMuse: 表单恢复与异步保存使用独立实现，避免主线程写盘及失败丢草稿。
import androidx.activity.compose.BackHandler
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.saveable.rememberSaveable
import io.github.nanomuse.models.ProviderModelDraft
import io.github.nanomuse.ui.models.ProviderSaveError
import io.github.nanomuse.ui.models.ProviderSaveProgress
import io.github.nanomuse.ui.models.rememberProviderSaveAction
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Bolt
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.res.stringResource
import com.openminis.app.data.model.ModelEntry
import com.openminis.app.data.model.normalizeModalityName
import com.openminis.app.data.repository.ProviderRepository
import com.openminis.app.ui.components.RowLabel
import com.openminis.app.ui.components.SectionTextField
import com.openminis.app.R
import com.openminis.app.ui.components.MinisButton
import com.openminis.app.ui.components.MinisTextButton
import kotlinx.serialization.json.Json

/**
 * Detail / edit screen for a single ModelEntry. T210: brought to iOS
 * parity with five inset-grouped sections — Identity, Capabilities,
 * Visibility, Input Modality, Output Modality (+ optional Reset). The
 * data layer (`ModelOverrides.contextWindow`, `supportsReasoning`,
 * `inputModalities`, `outputModalities`) was already in place; pre-T210
 * the UI only exposed displayName / maxOutputTokens / hidden, which
 * meant Android users had no way to override the things iOS lets them
 * tweak (context window, thinking flag, per-modality enablement).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ModelEntryDetailScreen(
    instanceId: String,
    entryId: String,
    providerRepository: ProviderRepository,
    onBack: () -> Unit,
) {
    // nanoMuse: 编辑页只在保存落盘后返回，关闭入口遵守相同的忙碌状态。
    val saveAction = rememberProviderSaveAction()
    BackHandler(enabled = saveAction.isSaving) { }
    ProviderSaveError(saveAction)
    val config by providerRepository.config.collectAsState()
    val isLoaded by providerRepository.configLoaded.collectAsState() // nanoMuse
    val entry = config.modelEntries.find { it.id == entryId && it.providerInstanceId == instanceId }
    val instance = config.instances.find { it.id == instanceId }

    if (entry == null) {
        // nanoMuse: 改模型ID后旧条目消失，由保存回调返回，避免配置流再次弹出上一页。
        LaunchedEffect(isLoaded, entryId, saveAction.isSaving, saveAction.hasSaved) {
            if (isLoaded && !saveAction.isSaving && !saveAction.hasSaved) onBack()
        }
        return
    }

    // nanoMuse: 基线随草稿共同恢复，配置流刷新和系统重建都不能把旧输入冒充为新快照。
    val baselineJson = rememberSaveable(entryId) { Json.encodeToString(ModelEntry.serializer(), entry) }
    val baseline = remember(baselineJson) { Json.decodeFromString(ModelEntry.serializer(), baselineJson) }
    val baseModel = baseline.baseModel
    val overrides = baseline.overrides

    // nanoMuse: 系统重建页面时保留输入，切换模型时使用新的表单状态。
    var modelId by rememberSaveable(entryId) { mutableStateOf(baseModel.id) }
    var displayName by rememberSaveable(entryId) { mutableStateOf(overrides.displayName ?: baseModel.displayName) }
    var maxOutputTokensText by rememberSaveable(entryId) { mutableStateOf(overrides.maxOutputTokens?.toString() ?: "") }
    var contextWindowText by rememberSaveable(entryId) { mutableStateOf(overrides.contextWindow?.toString() ?: "") }
    var thinkingEnabled by rememberSaveable(entryId) {
        mutableStateOf(overrides.supportsReasoning ?: baseModel.supportsReasoning ?: false)
    }
    var isHidden by rememberSaveable(entryId) { mutableStateOf(baseline.isHidden) } // nanoMuse
    var showQuickTest by remember { mutableStateOf(false) }

    // Modality state — derive from override-or-base so the toggles reflect
    // what the model actually supports today, then let the user flip from
    // there. A null override means "inherit baseModel" (data-layer
    // contract); on save we only persist a non-null list when it diverges
    // from the inherited set.
    // Defensive normalization: pre-T213 SharedPreferences may hold suffixed strings
    // (`image_input`) saved before the parse-boundary fix, which would silently fail
    // the bare-name `"image" in effectiveInput` checks below.
    val effectiveInput = (overrides.inputModalities ?: baseModel.inputModalities ?: emptyList())
        .map { it.normalizeModalityName() }
    val effectiveOutput = (overrides.outputModalities ?: baseModel.outputModalities ?: emptyList())
        .map { it.normalizeModalityName() }
    // nanoMuse: 能力开关与身份字段共同恢复，防止重建后混合新旧表单。
    var imageInput by rememberSaveable(entryId) { mutableStateOf("image" in effectiveInput) }
    var pdfInput by rememberSaveable(entryId) { mutableStateOf("pdf" in effectiveInput) }
    var audioInput by rememberSaveable(entryId) { mutableStateOf("audio" in effectiveInput) }
    var videoInput by rememberSaveable(entryId) { mutableStateOf("video" in effectiveInput) }
    var imageOutput by rememberSaveable(entryId) { mutableStateOf("image" in effectiveOutput) }
    var audioOutput by rememberSaveable(entryId) { mutableStateOf("audio" in effectiveOutput) }
    var videoOutput by rememberSaveable(entryId) { mutableStateOf("video" in effectiveOutput) }

    SettingsScaffold(
        title = stringResource(R.string.model_entry_model_detail),
        // [T-android-modeldetail-savecancel-ios-parity] iOS modal pattern
        // (ProviderInstanceDetailView toolbar): Cancel is a plain leading
        // text action, the title is centered, and Save is the single
        // emphasized trailing action — the filled pill is the MD3 analog of
        // iOS's semibold Save. No back arrow: Cancel and system back both
        // discard + pop.
        onBack = null,
        centerTitle = true,
        navigation = {
            MinisTextButton(
                onClick = onBack,
                enabled = !saveAction.isSaving, // nanoMuse
                modifier = Modifier.padding(start = 8.dp),
                colors = ButtonDefaults.textButtonColors(
                    contentColor = MaterialTheme.colorScheme.onSurfaceVariant,
                ),
            ) { Text(stringResource(R.string.common_cancel)) }
        },
        actions = {
            MinisButton(
                onClick = {
                    // nanoMuse: 先固定点击时的输入，再在后台验证并提交；保留表单未展示的能力。
                    val draft = ProviderModelDraft(modelId, displayName, maxOutputTokensText,
                        contextWindowText, thinkingEnabled, isHidden, imageInput, pdfInput,
                        audioInput, videoInput, imageOutput, audioOutput, videoOutput)
                    saveAction.submit(
                        save = { providerRepository.applyModelDraft(baseline, draft) },
                        onSaved = onBack,
                    )
                },
                enabled = !saveAction.isSaving && (!entry.isCustom || modelId.isNotBlank()), // nanoMuse
                modifier = Modifier.padding(end = 8.dp),
            ) {
                ProviderSaveProgress(saveAction) // nanoMuse: 写入时给出可见反馈。
                Text(stringResource(R.string.common_save))
            }
        },
    ) {
        // ── Identity ────────────────────────────────────────────────────
        SettingsSection(
            header = stringResource(R.string.add_provider_identity),
            footer = if (entry.isCustom) stringResource(R.string.modeldetail_identity_footer_custom)
                     else stringResource(R.string.modeldetail_identity_footer_builtin),
        ) {
            SettingsCardBlock {
                RowLabel(text = stringResource(R.string.add_custom_model_model_id))
                SectionTextField(
                    value = modelId,
                    onValueChange = { if (entry.isCustom && !saveAction.isSaving) modelId = it }, // nanoMuse
                    singleLine = true,
                    readOnly = !entry.isCustom,
                    textStyle = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
                )
                Spacer(Modifier.height(12.dp))
                RowLabel(text = stringResource(R.string.model_entry_display_name))
                SectionTextField(
                    value = displayName,
                    onValueChange = { if (!saveAction.isSaving) displayName = it }, // nanoMuse
                    singleLine = true,
                )
            }
            SettingsValueRow(
                title = stringResource(R.string.model_entry_provider),
                value = instance?.label ?: instanceId,
                showDivider = false,
            )
        }

        // ── Capabilities ────────────────────────────────────────────────
        SettingsSection(
            header = stringResource(R.string.modeldetail_section_capabilities),
            footer = stringResource(R.string.modeldetail_capabilities_footer),
        ) {
            SettingsCardBlock {
                RowLabel(text = stringResource(R.string.modeldetail_context_window))
                SectionTextField(
                    value = contextWindowText,
                    onValueChange = { if (!saveAction.isSaving) contextWindowText = it.filter { c -> c.isDigit() } }, // nanoMuse
                    placeholder = baseModel.contextWindow?.toString()
                        ?: stringResource(R.string.modeldetail_provider_default),
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                )
                // nanoMuse: 正在使用的上下文长度和它的来源，随输入更新。
                val contextOverride = contextWindowText.trim().toIntOrNull()?.takeIf { it > 0 }
                val capacitySource = io.github.nanomuse.models.ModelCapacity.source(baseModel, contextOverride, entry.isCustom)
                Spacer(Modifier.height(6.dp))
                Text(
                    stringResource(capacitySource.label, contextOverride ?: baseModel.contextWindowTokens),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(12.dp))
                RowLabel(text = stringResource(R.string.model_entry_max_output_tokens))
                SectionTextField(
                    value = maxOutputTokensText,
                    onValueChange = { if (!saveAction.isSaving) maxOutputTokensText = it.filter { c -> c.isDigit() } }, // nanoMuse
                    placeholder = baseModel.maxOutputTokens?.toString()
                        ?: stringResource(R.string.modeldetail_provider_default),
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                )
                // Inline warning when the value exceeds the provider-reported
                // limit. The save still goes through so power users can probe
                // a higher cap; we just flag it.
                val enteredTokens = maxOutputTokensText.trim().toIntOrNull()
                val baseLimit = baseModel.maxOutputTokens
                if (enteredTokens != null && baseLimit != null && enteredTokens > baseLimit) {
                    Spacer(Modifier.height(6.dp))
                    Text(
                        stringResource(R.string.modeldetail_max_tokens_exceeds_warning, baseLimit),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.error.copy(alpha = 0.8f),
                    )
                }
            }
            SettingsSwitchRow(
                title = stringResource(R.string.modeldetail_thinking),
                checked = thinkingEnabled,
                onCheckedChange = { if (!saveAction.isSaving) thinkingEnabled = it }, // nanoMuse
                showDivider = false,
            )
        }

        // ── Visibility ──────────────────────────────────────────────────
        SettingsSection(
            header = stringResource(R.string.model_entry_visibility),
            footer = stringResource(R.string.model_entry_hidden_models_won_t_appear_in_the_model_),
        ) {
            SettingsSwitchRow(
                title = stringResource(R.string.model_entry_hidden),
                checked = isHidden,
                onCheckedChange = { if (!saveAction.isSaving) isHidden = it }, // nanoMuse
                showDivider = false,
            )
        }

        // ── Input Modality ──────────────────────────────────────────────
        SettingsSection(
            header = stringResource(R.string.modeldetail_section_input_modality),
            footer = stringResource(R.string.modeldetail_input_modality_footer),
        ) {
            SettingsSwitchRow(
                title = stringResource(R.string.modeldetail_image_input),
                checked = imageInput,
                onCheckedChange = { if (!saveAction.isSaving) imageInput = it }, // nanoMuse
            )
            SettingsSwitchRow(
                title = stringResource(R.string.modeldetail_pdf_input),
                checked = pdfInput,
                onCheckedChange = { if (!saveAction.isSaving) pdfInput = it }, // nanoMuse
            )
            SettingsSwitchRow(
                title = stringResource(R.string.modeldetail_audio_input),
                checked = audioInput,
                onCheckedChange = { if (!saveAction.isSaving) audioInput = it }, // nanoMuse
            )
            SettingsSwitchRow(
                title = stringResource(R.string.modeldetail_video_input),
                checked = videoInput,
                onCheckedChange = { if (!saveAction.isSaving) videoInput = it }, // nanoMuse
                showDivider = false,
            )
        }

        // ── Output Modality ─────────────────────────────────────────────
        SettingsSection(
            header = stringResource(R.string.modeldetail_section_output_modality),
            footer = stringResource(R.string.modeldetail_output_modality_footer),
        ) {
            SettingsSwitchRow(
                title = stringResource(R.string.modeldetail_image_output),
                checked = imageOutput,
                onCheckedChange = { if (!saveAction.isSaving) imageOutput = it }, // nanoMuse
            )
            SettingsSwitchRow(
                title = stringResource(R.string.modeldetail_audio_output),
                checked = audioOutput,
                onCheckedChange = { if (!saveAction.isSaving) audioOutput = it }, // nanoMuse
            )
            // nanoMuse: a relay's video model whose name does not say so is marked here,
            // and is then offered for clips (io.github.nanomuse.media.MediaModels).
            SettingsSwitchRow(
                title = stringResource(R.string.modeldetail_video_output),
                checked = videoOutput,
                onCheckedChange = { if (!saveAction.isSaving) videoOutput = it }, // nanoMuse
                showDivider = false,
            )
        }

        // ── Quick Test ──
        SettingsSection(
            footer = stringResource(R.string.quicktest_footer),
        ) {
            SettingsRow(
                title = stringResource(R.string.quicktest_button),
                icon = Icons.Outlined.Bolt,
                showChevron = false,
                showDivider = false,
                onClick = { if (!saveAction.isSaving) showQuickTest = true }, // nanoMuse
            )
        }

        // ── Reset (only for built-in models that have been customized) ──
        if (!entry.isCustom && entry.isUserModified) {
            SettingsSection(
                footer = stringResource(R.string.model_entry_restores_the_provider_reported_display_n),
            ) {
                SettingsRow(
                    title = stringResource(R.string.model_entry_reset_to_default),
                    titleColor = MaterialTheme.colorScheme.error,
                    showChevron = false,
                    showDivider = false,
                    onClick = {
                        // nanoMuse: 重置同样等待落盘，失败时保留当前输入。
                        saveAction.submit(
                            save = { providerRepository.resetModelEntry(baseline) },
                            onSaved = onBack,
                        )
                    },
                )
            }
        }

        Spacer(Modifier.height(20.dp))
    }

    if (showQuickTest) {
        com.openminis.app.ui.components.QuickTestSheet(
            entry = entry,
            providerRepository = providerRepository,
            onDismiss = { showQuickTest = false },
        )
    }
}
