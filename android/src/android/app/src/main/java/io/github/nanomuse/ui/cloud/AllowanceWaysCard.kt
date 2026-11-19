package io.github.nanomuse.ui.cloud

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openminis.app.R
import com.openminis.app.ui.chat.ChatLinkResolver
import io.github.nanomuse.cloud.AllowanceSignal
import io.github.nanomuse.ui.home.MuseTones

/** 兼容旧聊天中的额度提示，仅提供本地服务商设置，不再显示邀请或推荐站。 */
@Suppress("UNUSED_PARAMETER")
@Composable
fun AllowanceWaysCard(
    info: AllowanceSignal.Exhausted,
    exhausted: Boolean,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    Surface(
        shape = RoundedCornerShape(20.dp),
        color = MuseTones.surface,
        border = BorderStroke(1.dp, MuseTones.hairline),
        modifier = modifier.fillMaxWidth().widthIn(max = 400.dp),
    ) {
        Column(Modifier.padding(14.dp)) {
            Text(
                text = stringResource(R.string.nm_ways_key_title),
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
            )
            TextButton(onClick = {
                ChatLinkResolver.dispatchDeepLink(context, "minis://settings/providers")
            }) {
                Text(
                    stringResource(R.string.nm_reach_open_provider),
                    fontSize = 13.sp,
                    color = MuseTones.action,
                )
            }
        }
    }
}
