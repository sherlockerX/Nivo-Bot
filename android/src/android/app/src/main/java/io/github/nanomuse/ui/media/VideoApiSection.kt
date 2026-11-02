package io.github.nanomuse.ui.media

import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import com.openminis.app.R
import com.openminis.app.data.model.ProviderInstance
import com.openminis.app.ui.settings.SettingsCardBlock
import com.openminis.app.ui.settings.SettingsSection
import io.github.nanomuse.media.MediaModels
import io.github.nanomuse.media.RelayVideo

/**
 * Mosaic: a provider page's "Video generation", the counterpart of its "Image generation" for a
 * relay of one's own: which video API the relay speaks (Automatic, new-api's or OpenAI's) and
 * the video models it lists, with how to mark one whose name does not say so. Model Studio has
 * its own API and gets no section.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun VideoApiSection(instance: ProviderInstance) {
    val context = LocalContext.current
    // A relay: an address of the person's own, and no vendor the catalogue says has no clips (DeepSeek, Kimi…).
    val relay = !instance.customBaseURL.isNullOrBlank() && MediaModels.isRelayVideo(context, instance) &&
        io.github.nanomuse.cloud.Capabilities.allows(context, instance, io.github.nanomuse.cloud.ProviderCatalogue.VIDEO)
    if (!relay) return
    var api by remember(instance.id) { mutableStateOf(MediaModels.videoApi(context, instance.id)) }
    val models = MediaModels.listedVideoModels(context, instance)
    val how = stringResource(
        when (api) {
            RelayVideo.Api.AUTO -> R.string.nm_video_api_auto_footer
            RelayVideo.Api.NEW_API -> R.string.nm_video_api_newapi_footer
            RelayVideo.Api.OPENAI -> R.string.nm_video_api_openai_footer
        },
    )
    val which = if (models.isEmpty()) stringResource(R.string.nm_video_api_no_models)
    else stringResource(R.string.nm_video_api_models, models.joinToString("、"))
    SettingsSection(header = stringResource(R.string.nm_video_api_title), footer = "$how\n$which") {
        SettingsCardBlock {
            // Equal heights and no check mark, so the three options keep one size on any screen.
            SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth().height(IntrinsicSize.Min)) {
                val choices = RelayVideo.Api.entries
                choices.forEachIndexed { i, choice ->
                    SegmentedButton(
                        selected = api == choice,
                        onClick = {
                            api = choice
                            MediaModels.setVideoApi(context, instance.id, choice)
                        },
                        shape = SegmentedButtonDefaults.itemShape(index = i, count = choices.size),
                        modifier = Modifier.fillMaxHeight(),
                        icon = {},
                    ) {
                        Text(
                            stringResource(
                                when (choice) {
                                    RelayVideo.Api.AUTO -> R.string.nm_video_api_auto
                                    RelayVideo.Api.NEW_API -> R.string.nm_video_api_newapi
                                    RelayVideo.Api.OPENAI -> R.string.nm_video_api_openai
                                },
                            ),
                            textAlign = TextAlign.Center,
                        )
                    }
                }
            }
        }
    }
}
