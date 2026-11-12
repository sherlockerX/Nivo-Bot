package io.github.nanomuse.ui.ideas

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import io.github.nanomuse.ideas.DailyIdeaCatalogue
import io.github.nanomuse.ideas.DailyIdeaEdition
import io.github.nanomuse.ideas.DailyIdeaSection
import io.github.nanomuse.ideas.DailyIdeas
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

/** 恢复时立即检查日期，前台午夜刷新，并适应设备时区或时间调整。 */
@Composable
fun rememberLocalIdeaDate(): LocalDate {
    var date by remember { mutableStateOf(LocalDate.now()) }
    val owner = LocalLifecycleOwner.current
    LaunchedEffect(owner) {
        owner.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            while (true) {
                val now = Instant.now()
                val zone = ZoneId.systemDefault()
                date = DailyIdeas.localDate(now, zone)
                delay(DailyIdeas.refreshDelayMillis(now, zone))
            }
        }
    }
    return date
}

/** 完整点子页与主聊天使用相同素材及日期选取规则。 */
@Composable
fun rememberDailyIdeaEdition(): DailyIdeaEdition {
    val context = LocalContext.current.applicationContext
    val configuration = LocalConfiguration.current
    val language = configuration.locales[0]?.language ?: "en"
    val date = rememberLocalIdeaDate()
    // 读过的素材直接作首帧，条带出现时不再先空后满。
    // 语言变化创建独立状态，旧语言的迟到加载结果不能暂时占据新语言首帧。
    val sections by key(context, language) {
        produceState<List<DailyIdeaSection>>(DailyIdeaCatalogue.cached(language) ?: emptyList()) {
            value = withContext(Dispatchers.IO) { DailyIdeaCatalogue.load(context, language) }
        }
    }
    return remember(sections, date) { DailyIdeas.select(sections, date) }
}
