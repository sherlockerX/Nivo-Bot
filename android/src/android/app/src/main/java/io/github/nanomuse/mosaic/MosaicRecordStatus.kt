package io.github.nanomuse.mosaic

/** 日历日期圈的状态，加载期间不把未知数据误判为空记录。 */
enum class RecordDayStatus { RECORDED, MISSING, FUTURE, LOADING }

/** 按已保存记录数量判断日期圈，习惯勾选不等于写日记。 */
fun recordDayStatus(day: Long, today: Long, entryCount: Int?): RecordDayStatus = when {
    day > today -> RecordDayStatus.FUTURE
    entryCount == null -> RecordDayStatus.LOADING
    entryCount > 0 -> RecordDayStatus.RECORDED
    else -> RecordDayStatus.MISSING
}

/** 日期输入只接受四位公历年，编辑时同时检查最晚日期。 */
fun parseDiaryPickerDate(text: String, latest: java.time.LocalDate?): java.time.LocalDate? =
    text.takeIf { Regex("\\d{4}-\\d{2}-\\d{2}").matches(it) }
        ?.let { runCatching { java.time.LocalDate.parse(it) }.getOrNull() }
        ?.takeIf { it.year in 1..9999 && (latest == null || !it.isAfter(latest)) }
