package io.github.nanomuse.mosaic

import java.time.Clock
import java.time.LocalDate
import java.time.ZoneId

/** 已校验的只读查询，每页按完整日期切分，避免把同一天的日记拆散。 */
internal data class JigsawQuery(
    val command: String,
    val range: MosaicRange,
    val limit: Int,
    val offset: Int,
    val format: String,
    val today: Long,
) {
    val page: MosaicRange get() = MosaicRange(range.start.plusDays(offset.toLong()),
        minOf(range.endExclusive, range.start.plusDays(offset.toLong() + limit)))
    val nextOffset: Int? get() = (offset + page.length).takeIf { it < range.length }

    companion object {
        val ZONE: ZoneId = ZoneId.of("Asia/Shanghai")
        private val COMMANDS = setOf("list", "get", "stats", "export")

        /** 严格检查日期、参数和边界，未知或写入请求在访问数据库之前返回错误。 */
        fun parse(argv: List<String>, clock: Clock): JigsawQuery {
            val command = argv.first()
            require(command in COMMANDS) { "Only list, get, stats and export are supported." }
            val options = options(argv.drop(1))
            val allowed = when (command) {
                "get" -> setOf("date", "format")
                "stats" -> setOf("start", "end", "days", "format")
                else -> setOf("start", "end", "days", "limit", "offset", "format")
            }
            require(options.keys.all { it in allowed }) { "Unsupported option. Output is stdout only; use --help." }
            val format = options["format"] ?: "json"
            require(format in setOf("json", "md")) { "--format must be json or md." }
            val range = range(command, options, clock)
            val limit = number(options, "limit", 31, 1..366)
            val offset = number(options, "offset", 0, 0..365)
            require(offset < range.length) { "--offset must be smaller than the number of days in the range." }
            return JigsawQuery(command, range, limit, offset, format, LocalDate.now(clock.withZone(ZONE)).toEpochDay())
        }

        private fun options(argv: List<String>): Map<String, String> {
            val values = linkedMapOf<String, String>()
            var index = 0
            while (index < argv.size) {
                val token = argv[index++]
                require(token.startsWith("--")) { "Expected an option beginning with --." }
                val rawKey = token.removePrefix("--").substringBefore('=')
                val key = when (rawKey) { "from" -> "start"; "to", "until" -> "end"; else -> rawKey }
                val value = if ('=' in token) token.substringAfter('=') else argv.getOrNull(index++)
                require(!value.isNullOrBlank() && !value.startsWith("--")) { "Option --$rawKey needs a value." }
                require(key !in values) { "Option --$key was supplied more than once." }
                values[key] = value
            }
            return values
        }

        private fun range(command: String, options: Map<String, String>, clock: Clock): MosaicRange {
            if (command == "get") {
                val date = date(requireNotNull(options["date"]) { "get requires --date YYYY-MM-DD." })
                return MosaicRange(date, date.plusDays(1))
            }
            val end = options["end"]?.let(::date) ?: LocalDate.now(clock.withZone(ZONE))
            val days = number(options, "days", 7, 1..366)
            val start = options["start"]?.let(::date) ?: end.minusDays(days - 1L)
            require(!start.isAfter(end)) { "--start must not be after --end." }
            val range = MosaicRange(start, end.plusDays(1))
            require(range.length in 1..366) { "Read at most 366 days at a time." }
            return range
        }

        private fun date(value: String): LocalDate {
            require(Regex("\\d{4}-\\d{2}-\\d{2}").matches(value)) { "Dates must use YYYY-MM-DD." }
            return try { LocalDate.parse(value) }
            catch (_: java.time.format.DateTimeParseException) { throw IllegalArgumentException("Invalid calendar date.") }
        }

        private fun number(options: Map<String, String>, key: String, default: Int, range: IntRange): Int {
            val raw = options[key] ?: return default
            val value = raw.toIntOrNull()
            require(value != null && value in range) { "--$key must be an integer in ${range.first}..${range.last}." }
            return value
        }
    }
}
