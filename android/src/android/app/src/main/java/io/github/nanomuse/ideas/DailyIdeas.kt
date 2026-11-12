package io.github.nanomuse.ideas

import java.net.URI
import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import org.json.JSONObject

private const val IDEAS_PER_DAY = 2
private const val MAX_REFRESH_DELAY_MILLIS = 60_000L
private const val HOT_TOPIC_MAX_AGE_HOURS = 48L

/** 每日点子的展示分类，与目标分类独立。 */
enum class DailyIdeaCategory(val key: String) {
    IDEAS("ideas"), WORK("work"), LIFE("life"), LEARN("learn"),
    FAMILY("family"), MEDIA("media"), MORE("more"),
}

/** 热点的来源和核验时间，仅供未来可信来源接入使用。 */
data class DailyIdeaSource(
    val publisher: String,
    val url: String,
    val publishedAt: Instant,
    val verifiedAt: Instant,
)

/** 点击后交给现有聊天输入框的点子，不会自行执行。 */
data class DailyIdea(
    val id: String,
    val emoji: String,
    val title: String,
    val body: String,
    val prompt: String,
    val isHotTopic: Boolean = false,
    val source: DailyIdeaSource? = null,
) {
    /** 只有证据完整且未过期的内容才能显示热点标记。 */
    fun hasVerifiedHotTopic(now: Instant): Boolean {
        val evidence = source ?: return false
        if (!isHotTopic || evidence.publisher.isBlank()) return false
        val uri = runCatching { URI(evidence.url) }.getOrNull() ?: return false
        if (uri.scheme != "https" || uri.host.isNullOrBlank() || uri.userInfo != null) return false
        if (evidence.verifiedAt < evidence.publishedAt || evidence.verifiedAt > now) return false
        val age = Duration.between(evidence.publishedAt, now)
        return !age.isNegative && age <= Duration.ofHours(HOT_TOPIC_MAX_AGE_HOURS)
    }
}

/** 同一分类的本地素材或当天选取结果。 */
data class DailyIdeaSection(
    val category: DailyIdeaCategory,
    val title: String,
    val ideas: List<DailyIdea>,
)

/** 以设备当地日期标识、日内稳定的每日版本。 */
data class DailyIdeaEdition(val localDate: LocalDate, val sections: List<DailyIdeaSection>)

/** 每日选取与日期计算保持纯函数，便于离线测试。 */
object DailyIdeas {
    /** 每个分类每天展示两条。 */
    fun select(sections: List<DailyIdeaSection>, date: LocalDate): DailyIdeaEdition {
        val selected = sections.sortedBy { it.category.ordinal }.map { section ->
            val pool = section.ideas.distinctBy { it.id }.sortedBy { it.id }
            section.copy(ideas = selectPool(pool, date.toEpochDay()))
        }
        return DailyIdeaEdition(date, selected)
    }

    private fun selectPool(pool: List<DailyIdea>, epochDay: Long): List<DailyIdea> {
        if (pool.isEmpty()) return emptyList()
        val count = minOf(IDEAS_PER_DAY, pool.size)
        val start = Math.floorMod(epochDay * IDEAS_PER_DAY, pool.size.toLong()).toInt()
        return List(count) { offset -> pool[(start + offset) % pool.size] }
    }

    /** 读取指定时区下的当地日期。 */
    fun localDate(now: Instant, zone: ZoneId): LocalDate = now.atZone(zone).toLocalDate()

    /** 按日历计算下一天，兼容夏令时的长短日。 */
    fun nextLocalDay(now: Instant, zone: ZoneId): Instant =
        localDate(now, zone).plusDays(1).atStartOfDay(zone).toInstant()

    /** 最多一分钟重查设备时间，临近午夜时缩短等待。 */
    fun refreshDelayMillis(now: Instant, zone: ZoneId): Long =
        Duration.between(now, nextLocalDay(now, zone)).toMillis()
            .coerceIn(1L, MAX_REFRESH_DELAY_MILLIS)

    /** 解析Android专用素材池。缺字段的单条点子跳过，不连累整个目录；点子 id 全局去重，列表的 key 才不会重复。 */
    fun parse(text: String): List<DailyIdeaSection> {
        val sections = JSONObject(text).getJSONArray("sections")
        val seen = HashSet<String>()
        return (0 until sections.length()).mapNotNull { index ->
            parseSection(sections.getJSONObject(index), seen)
        }
    }

    private fun parseSection(section: JSONObject, seen: MutableSet<String>): DailyIdeaSection? {
        val category = DailyIdeaCategory.entries.firstOrNull { it.key == section.optString("id") }
            ?: return null
        val ideas = section.getJSONArray("ideas")
        return DailyIdeaSection(category, section.getString("title"),
            (0 until ideas.length()).mapNotNull { i ->
                runCatching { parseIdea(ideas.getJSONObject(i)) }.getOrNull()?.takeIf { seen.add(it.id) }
            })
    }

    private fun parseIdea(idea: JSONObject): DailyIdea = DailyIdea(
        id = idea.getString("id"),
        emoji = idea.optString("emoji", "💡"),
        title = idea.getString("title"),
        body = idea.getString("body"),
        prompt = idea.getString("prompt"),
        isHotTopic = idea.optBoolean("hot", false),
        source = parseSource(idea.optJSONObject("source")),
    )

    private fun parseSource(source: JSONObject?): DailyIdeaSource? {
        if (source == null) return null
        return runCatching {
            DailyIdeaSource(source.getString("publisher"), source.getString("url"),
                Instant.parse(source.getString("publishedAt")), Instant.parse(source.getString("verifiedAt")))
        }.getOrNull()
    }
}
