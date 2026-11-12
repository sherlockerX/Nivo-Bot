package io.github.nanomuse.ideas

import java.time.LocalDate

/** 独立于每日素材轮换的热点核实请求，不执行联网或发布。 */
object DailyHotTopicPrompt {
    /** 使用入口显示的当地日期生成待用户发送的核实请求。 */
    fun create(date: LocalDate, language: String): String =
        if (language.startsWith("zh", ignoreCase = true)) {
            """
            帮我查今天可拍的热点。设备当地日期为$date；发送时间可能晚于填入时间，请先重新核对当地日期。
            请主动联网，围绕我已有的领域信息查询；只有领域确实不清楚时才先问一个必要问题。
            每个候选至少两个可独立核查的来源，优先原始发布者，提供可打开的https链接、发布者、发布时间、核验时间和事件发生时间。
            不能把旧闻说成今天发生，不能凭热度猜测或没有来源的说法称为热点，区分查证事实与尚不确定的部分。
            无法联网、来源不足或日期不明时请明确说明，改给一个同领域常青选题。
            核实后给出可拍角度、30至60秒脚本、3至5个实际镜头、所需素材及版权或隐私注意点。不要发布内容或自动创建定时任务。
            """.trimIndent()
        } else {
            """
            Find a current story I can film today. The device-local date is $date; recheck the local date when this request is sent.
            Please actively browse using the topic context I have already provided. Ask one necessary question only if my topic is unclear.
            For each candidate, check at least two independently checkable sources and prioritize the original publisher. Provide working https links, publisher names, publication time, verification time, and event date.
            Do not present old news as happening today or call unsupported popularity claims verified stories. Separate verified facts from uncertainty.
            If browsing is unavailable, sources are insufficient, or dates are unclear, say so and offer one related evergreen topic.
            After checking, give a filming angle, a 30 to 60 second script, three to five practical shots, materials, and copyright or privacy considerations. Do not publish content or create scheduled tasks.
            """.trimIndent()
        }
}
