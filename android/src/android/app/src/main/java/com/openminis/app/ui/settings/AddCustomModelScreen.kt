package com.openminis.app.ui.settings

// nanoMuse: 保存状态与错误提示统一处理，失败保留表单。
import androidx.activity.compose.BackHandler
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.saveable.rememberSaveable
import io.github.nanomuse.ui.models.ProviderSaveError
import io.github.nanomuse.ui.models.ProviderSaveProgress
import io.github.nanomuse.ui.models.rememberProviderSaveAction
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.res.stringResource
import com.openminis.app.data.model.LLMModel
import com.openminis.app.data.model.ModelEntry
import com.openminis.app.data.model.withInferredVoiceModality
import com.openminis.app.data.repository.ProviderRepository
import com.openminis.app.ui.components.RowLabel
import com.openminis.app.ui.components.SectionTextField
import com.openminis.app.R
import com.openminis.app.ui.components.MinisButton

/**
 * Add Custom Model — adopts the SettingsScaffold/SettingsSection toolkit
 * (T78). Single Identity section grouping the Model ID + Display Name
 * fields, with a footer caption explaining what the fields are for.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AddCustomModelScreen(
    instanceId: String,
    providerRepository: ProviderRepository,
    onBack: () -> Unit,
) {
    // nanoMuse: 首次加载不能被误当成供应商已删除。
    val config by providerRepository.config.collectAsState()
    val isLoaded by providerRepository.configLoaded.collectAsState()
    val instance = config.instances.firstOrNull { it.id == instanceId }
    val saveAction = rememberProviderSaveAction()
    BackHandler(enabled = saveAction.isSaving) { }
    ProviderSaveError(saveAction)

    if (instance == null) {
        // nanoMuse: 同时删除供应商时等待保存结束，并避免成功回调后的重复返回。
        LaunchedEffect(isLoaded, instanceId, saveAction.isSaving, saveAction.hasSaved) {
            if (isLoaded && !saveAction.isSaving && !saveAction.hasSaved) onBack()
        }
        return
    }

    // nanoMuse: 页面重建后保留新增模型草稿。
    var modelId by rememberSaveable(instanceId) { mutableStateOf("") }
    var displayName by rememberSaveable(instanceId) { mutableStateOf("") }

    SettingsScaffold(
        title = stringResource(R.string.provider_detail_add_custom_model),
        onBack = { if (!saveAction.isSaving) onBack() }, // nanoMuse
    ) {
        SettingsSection(
            header = stringResource(R.string.add_provider_identity),
            footer = stringResource(R.string.add_custom_model_id_footer, instance.providerType.displayName),
        ) {
            SettingsCardBlock {
                RowLabel(text = stringResource(R.string.add_custom_model_model_id))
                SectionTextField(
                    value = modelId,
                    onValueChange = { if (!saveAction.isSaving) modelId = it }, // nanoMuse
                    placeholder = stringResource(R.string.add_custom_model_eg_id_placeholder),
                    singleLine = true,
                    textStyle = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
                )
                Spacer(Modifier.height(12.dp))
                RowLabel(text = stringResource(R.string.add_custom_model_display_name_optional))
                SectionTextField(
                    value = displayName,
                    onValueChange = { if (!saveAction.isSaving) displayName = it }, // nanoMuse
                    singleLine = true,
                )
            }
        }

        Spacer(Modifier.height(20.dp))
        MinisButton(
            onClick = {
                val name = displayName.ifBlank { modelId }
                val model = LLMModel(
                    id = modelId.trim(),
                    displayName = name.trim(),
                    provider = instance.providerType.displayName,
                ).withInferredVoiceModality() // nanoMuse: a typed-in speech model (qwen3-asr-flash, cosyvoice-v3-flash…) can be picked for voice, as a fetched one can
                val entry = ModelEntry(
                    providerInstanceId = instanceId,
                    baseModel = model,
                    isCustom = true,
                )
                // nanoMuse: 存储层检查重复ID并确认写入成功后才返回。
                saveAction.submit(
                    save = { providerRepository.addEntry(entry, requirePersistence = true) },
                    onSaved = onBack,
                )
            },
            enabled = modelId.isNotBlank() && !saveAction.isSaving, // nanoMuse
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp),
        ) {
            ProviderSaveProgress(saveAction) // nanoMuse: 写入时给出可见反馈。
            Text(stringResource(R.string.common_save))
        }
        Spacer(Modifier.height(20.dp))
    }
}
