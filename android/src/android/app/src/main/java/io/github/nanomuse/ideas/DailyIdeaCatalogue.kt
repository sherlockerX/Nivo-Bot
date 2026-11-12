package io.github.nanomuse.ideas

import android.content.Context
import com.openminis.app.logging.AppLogger
import java.util.concurrent.ConcurrentHashMap

/** 只读取内置素材，不联网、不生成内容、不创建例程。 */
object DailyIdeaCatalogue {
    /** 每种素材只读一次：条带随聊天反复出现，每次重读会先画空再撑开。 */
    private val loaded = ConcurrentHashMap<String, List<DailyIdeaSection>>()

    private fun suffix(language: String) = if (language == "zh") "zh" else "en"

    /** 已读过的素材，供界面首帧直接使用；没读过时为 null。 */
    fun cached(language: String): List<DailyIdeaSection>? = loaded[suffix(language)]

    /** 当前提供中英文素材，其他语言沿用英文内容。读取失败不缓存，下次再试。 */
    fun load(context: Context, language: String): List<DailyIdeaSection> {
        val suffix = suffix(language)
        loaded[suffix]?.let { return it }
        val path = "nanomuse/daily-ideas.$suffix.json"
        return runCatching {
            context.assets.open(path).bufferedReader().use { DailyIdeas.parse(it.readText()) }
        }.onSuccess {
            loaded[suffix] = it
        }.onFailure {
            AppLogger.warning("DailyIdeas", "每日点子素材无法读取：$path（${it.message}）")
        }.getOrDefault(emptyList())
    }
}

/** 保留点子页现有的确认和发送流程，每日点子统一发起普通聊天。 */
fun DailyIdea.asChatIdea(): Idea = Idea(id, emoji, title, body, IdeaKind.CHAT, prompt)
