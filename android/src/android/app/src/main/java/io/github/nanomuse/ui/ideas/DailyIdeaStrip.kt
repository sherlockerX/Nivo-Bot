package io.github.nanomuse.ui.ideas

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.clearAndSetSemantics
import io.github.nanomuse.ideas.DailyIdea
import com.openminis.app.R
import io.github.nanomuse.ideas.DailyIdeaCategory
import io.github.nanomuse.ideas.DailyIdeaEdition
import io.github.nanomuse.ideas.DailyHotTopicPrompt
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/** 主聊天下方的每日点子，点击只填入草稿，发送由用户决定。 */
@Composable
fun DailyIdeaStrip(onPrefill: (String) -> Unit, onOpenIdeas: () -> Unit) {
    val edition = rememberDailyIdeaEdition()
    DailyIdeaStripContent(edition, onPrefill, onOpenIdeas)
}

/** 素材加载前后保留同一卡片行高度，不挤动上方聊天；内容参数便于测量真实布局。 */
@Composable
internal fun DailyIdeaStripContent(
    edition: DailyIdeaEdition,
    onPrefill: (String) -> Unit,
    onOpenIdeas: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val configuration = androidx.compose.ui.platform.LocalConfiguration.current
    val density = LocalDensity.current
    val language = configuration.locales[0]?.language ?: "en"
    var categoryKey by rememberSaveable { mutableStateOf(DailyIdeaCategory.IDEAS.key) }
    val selectedCategory = DailyIdeaCategory.entries.firstOrNull { it.key == categoryKey }
        ?: DailyIdeaCategory.IDEAS
    val selected = edition.sections.firstOrNull { it.category.key == categoryKey }
        ?: edition.sections.firstOrNull()
    val shouldShowBody = configuration.fontScale <= 1.3f
    val typography = MaterialTheme.typography
    // 表情字体可能高于默认label行高，预留与实际文本相同的明确行高。
    val titleStyle = typography.labelLarge.copy(lineHeight = 24.sp)
    val bodyStyle = typography.bodySmall.copy(lineHeight = 20.sp)
    val cardMinHeight = with(density) {
        16.dp + titleStyle.lineHeight.toDp() +
            if (shouldShowBody) 2.dp + bodyStyle.lineHeight.toDp() else 0.dp
    }.coerceAtLeast(56.dp)
    // 三排默认约160dp；大字号保留标题并省略摘要，控件随文字自然增高。
    Column(modifier.fillMaxWidth().padding(vertical = 4.dp)) {
        Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (selectedCategory == DailyIdeaCategory.MEDIA) {
                TextButton(onClick = { onPrefill(DailyHotTopicPrompt.create(edition.localDate, language)) },
                    modifier = Modifier.weight(1f).heightIn(min = 48.dp)) {
                    Text(stringResource(R.string.nm_daily_ideas_check_hot_topic), maxLines = 1,
                        overflow = TextOverflow.Ellipsis)
                }
            } else {
                Text(stringResource(R.string.nm_daily_ideas_title) + " · " + dailyIdeaDateLabel(edition.localDate),
                    modifier = Modifier.weight(1f), style = MaterialTheme.typography.labelMedium,
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            TextButton(onClick = onOpenIdeas, modifier = Modifier.heightIn(min = 48.dp)) {
                Text(stringResource(R.string.nm_daily_ideas_all), maxLines = 1)
            }
        }
        LazyRow(contentPadding = PaddingValues(horizontal = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            items(DailyIdeaCategory.entries, key = { it.key }) { category ->
                FilterChip(selected = category.key == categoryKey,
                    onClick = { categoryKey = category.key },
                    label = { Text(dailyIdeaCategoryTitle(category), maxLines = 1) })
            }
        }
        LazyRow(modifier = Modifier.heightIn(min = cardMinHeight),
            contentPadding = PaddingValues(horizontal = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            // 使用同一真实文字布局预留字体回退及表情高度，不能仅按sp换算猜测像素。
            val isLoading = selected?.ideas.isNullOrEmpty()
            val cards = selected?.ideas?.takeIf { it.isNotEmpty() }
                ?: listOf(DailyIdea("loading", "💡", "Ag中", "Ag中", ""))
            items(cards, key = { it.id }) { idea ->
                Surface(shape = MaterialTheme.shapes.medium,
                    color = MaterialTheme.colorScheme.surfaceContainer,
                    modifier = Modifier.width(240.dp).heightIn(min = cardMinHeight)
                        .then(if (isLoading) Modifier.graphicsLayer { alpha = 0f }.clearAndSetSemantics { }
                            else Modifier.clickable { onPrefill(idea.prompt) })) {
                    Column(Modifier.padding(horizontal = 12.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text("${idea.emoji}${idea.title}", fontWeight = FontWeight.SemiBold,
                            style = titleStyle, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        if (shouldShowBody) Text(idea.body,
                            style = bodyStyle,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
        }
    }
}

/** 分类名称采用界面语言，素材本身使用已有的中英文回退策略。 */
@Composable
internal fun dailyIdeaCategoryTitle(category: DailyIdeaCategory): String = stringResource(
    when (category) {
        DailyIdeaCategory.IDEAS -> R.string.nm_daily_category_ideas
        DailyIdeaCategory.WORK -> R.string.nm_daily_category_work
        DailyIdeaCategory.LIFE -> R.string.nm_daily_category_life
        DailyIdeaCategory.LEARN -> R.string.nm_daily_category_learn
        DailyIdeaCategory.FAMILY -> R.string.nm_daily_category_family
        DailyIdeaCategory.MEDIA -> R.string.nm_daily_category_media
        DailyIdeaCategory.MORE -> R.string.nm_daily_category_more
    },
)

/** 日期按界面区域设置显示，不固定使用某个国家或时区。 */
@Composable
internal fun dailyIdeaDateLabel(date: LocalDate): String {
    val configuration = androidx.compose.ui.platform.LocalConfiguration.current
    val locale = configuration.locales[0] ?: java.util.Locale.getDefault()
    return date.format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withLocale(locale))
}
