package io.github.nanomuse.focus.lock

import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import org.json.JSONTokener

/** 只备份计划与白名单，不携带或恢复任何锁定会话。 */
object LockBackup {
    const val MAX_BACKUP_BYTES = 1_000_000
    const val MAX_FOCUS_BACKUP_BYTES = 8_000_000
    private const val MAX_JSON_DEPTH = 16
    private val DOCUMENT_FIELDS = setOf("format", "version", "plans", "whitelist")
    private val PLAN_FIELDS = setOf("id", "name", "days", "ranges", "isEnabled", "usesWhitelist", "title", "taskId", "revision")

    /** 恢复到当前账号且全部停用的配置，由存储层在同一事务内应用。 */
    data class Configuration(val ownerKey: String, val plans: List<LockPlan>, val whitelist: Set<String>)

    /** 有界解析现有专注备份，仅提取锁机配置，导入事务仍需检查活动锁。 */
    fun parseFocusConfiguration(text: String): JSONObject {
        validateText(text, MAX_FOCUS_BACKUP_BYTES)
        validateDepth(text)
        return try {
            val document = parseDocument(text)
            require(document.get("format") == "nanomuse-focus" && integer(document.get("version")) == 1L) {
                "专注备份版本不受支持"
            }
            document.getJSONObject("lock").also { validateText(it.toString()) }
        } catch (error: JSONException) {
            throw IllegalArgumentException("专注备份JSON无效", error)
        }
    }

    /** 提供给外层专注备份的配置对象，导出时保留原启用状态。 */
    fun encode(plans: List<LockPlan>, whitelist: Set<String>): JSONObject {
        LockConfigurationRules.validateConfiguration(plans, whitelist)
        return JSONObject().put("format", "nanomuse-focus-lock").put("version", 1)
            .put("plans", JSONArray(plans.map(::planJson)))
            .put("whitelist", JSONArray(whitelist.sorted())).also { validateText(it.toString()) }
    }

    /** 解码已读取的配置对象；持久层必须在同一事务内提供真实活动锁状态。 */
    fun decode(json: JSONObject, ownerKey: String, hasActiveRun: Boolean = false): Configuration {
        check(!hasActiveRun) { "focus_locked" }
        LockConfigurationRules.requireOwner(ownerKey)
        return try {
            // 对象入口先检查已知结构，避免未知或循环载荷先进入递归字符串化。
            decodeDocument(json, ownerKey).also { validateText(json.toString()) }
        } catch (error: JSONException) {
            throw IllegalArgumentException("锁机配置JSON无效", error)
        }
    }

    /** 序列化单一账号的配置快照，拒绝混入其他账号。 */
    fun encode(ownerKey: String, plans: List<LockPlan>, whitelist: Set<String>): String {
        LockConfigurationRules.requireOwner(ownerKey)
        require(plans.all { it.ownerKey == ownerKey }) { "备份不能混入其他账号的计划" }
        return encode(plans, whitelist).toString()
    }

    /** 活动锁期间禁止恢复；备份中的启用状态只作记录，恢复后必须重新启用。 */
    fun decode(text: String, targetOwnerKey: String, hasActiveRun: Boolean): Configuration {
        check(!hasActiveRun) { "focus_locked" }
        LockConfigurationRules.requireOwner(targetOwnerKey)
        validateText(text)
        validateDepth(text)
        return try {
            decodeDocument(parseDocument(text), targetOwnerKey)
        } catch (error: JSONException) {
            throw IllegalArgumentException("锁机配置JSON无效", error)
        }
    }

    private fun decodeDocument(json: JSONObject, ownerKey: String): Configuration {
        require(keys(json) == DOCUMENT_FIELDS) { "备份字段不受支持，不得恢复会话或源账号" }
        require(json.get("format") == "nanomuse-focus-lock" && integer(json.get("version")) == 1L) {
            "锁机配置备份版本不受支持"
        }
        val plans = boundedArray(json, "plans", LockConfigurationRules.MAX_PLANS).map { readPlan(it as? JSONObject
            ?: throw IllegalArgumentException("计划必须是JSON对象"), ownerKey) }
        require(plans.map { it.id }.distinct().size == plans.size) { "计划身份重复" }
        val packages = boundedArray(json, "whitelist", LockConfigurationRules.MAX_WHITELIST).map {
            it as? String ?: throw IllegalArgumentException("白名单包名必须是字符串")
        }
        require(packages.distinct().size == packages.size) { "白名单包名重复" }
        LockConfigurationRules.validateConfiguration(plans, packages.toSet())
        return Configuration(ownerKey, plans, packages.toSet())
    }

    private fun parseDocument(text: String): JSONObject {
        val parser = JSONTokener(text)
        val json = parser.nextValue() as? JSONObject ?: throw IllegalArgumentException("备份必须是JSON对象")
        require(parser.nextClean() == '\u0000') { "备份含有尾随内容" }
        return json
    }

    private fun planJson(plan: LockPlan): JSONObject = JSONObject()
        .put("id", plan.id).put("name", plan.name).put("days", JSONArray(plan.days.sorted()))
        .put("ranges", JSONArray(plan.ranges.map {
            JSONObject().put("startMinute", it.startMinute).put("endMinute", it.endMinute)
        })).put("isEnabled", plan.isEnabled).put("usesWhitelist", plan.usesWhitelist)
        .put("title", plan.title ?: JSONObject.NULL).put("taskId", plan.taskId ?: JSONObject.NULL)
        .put("revision", plan.revision)

    private fun readPlan(json: JSONObject, ownerKey: String): LockPlan {
        require(keys(json).all { it in PLAN_FIELDS }) { "计划含有未知字段" }
        val days = boundedArray(json, "days", 7).map { intValue(it) }
        require(days.distinct().size == days.size) { "星期重复" }
        val ranges = boundedArray(json, "ranges", LockConfigurationRules.MAX_RANGES).map(::readRange)
        require(json.get("isEnabled") is Boolean) { "启用状态必须是布尔值" }
        val usesWhitelist = json.get("usesWhitelist") as? Boolean
            ?: throw IllegalArgumentException("白名单状态必须是布尔值")
        // 文件中的启用状态只接受合法类型，恢复时强制停用，等待用户重新确认。
        return LockPlan(
            id = text(json.get("id")), name = text(json.get("name")), days = days.toSet(),
            ranges = ranges, isEnabled = false, usesWhitelist = usesWhitelist,
            title = optionalText(json, "title"), taskId = optionalText(json, "taskId"),
            ownerKey = ownerKey, revision = integer(json.get("revision"))
        ).also { LockConfigurationRules.validatePlan(it) }
    }

    private fun readRange(value: Any): TimeRange {
        val json = value as? JSONObject ?: throw IllegalArgumentException("时段必须是JSON对象")
        require(keys(json) == setOf("startMinute", "endMinute")) { "时段字段无效" }
        return TimeRange(intValue(json.get("startMinute")), intValue(json.get("endMinute")))
    }

    private fun boundedArray(json: JSONObject, key: String, maximum: Int): List<Any> {
        val array = json.getJSONArray(key)
        require(array.length() <= maximum) { "备份集合数量超限" }
        return (0 until array.length()).map { array.get(it) }
    }

    private fun integer(value: Any): Long {
        require(value is Int || value is Long) { "备份数字必须是Long范围内的整数" }
        return (value as Number).toLong()
    }

    private fun intValue(value: Any): Int {
        val number = integer(value)
        require(number in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong()) { "日历数字超出范围" }
        return number.toInt()
    }

    private fun text(value: Any): String = value as? String
        ?: throw IllegalArgumentException("备份文本字段必须是字符串")

    private fun optionalText(json: JSONObject, key: String): String? =
        if (!json.has(key) || json.isNull(key)) null else text(json.get(key))

    private fun keys(json: JSONObject): Set<String> = json.keys().asSequence().toSet()

    private fun validateText(text: String, maximumBytes: Int = MAX_BACKUP_BYTES) {
        require(text.length <= maximumBytes && text.toByteArray(Charsets.UTF_8).size <= maximumBytes) {
            "锁机配置备份超过大小上限"
        }
        require('\u0000' !in text) { "备份不能包含未转义的NUL字符" }
    }

    private fun validateDepth(text: String) {
        var depth = 0
        var quote: Char? = null
        var isEscaped = false
        for (character in text) {
            if (quote != null) {
                if (isEscaped) isEscaped = false
                else if (character == '\\') isEscaped = true
                else if (character == quote) quote = null
                continue
            }
            when (character) {
                '"', '\'' -> quote = character
                '{', '[' -> depth += 1
                '}', ']' -> depth -= 1
            }
            require(depth in 0..MAX_JSON_DEPTH) { "备份JSON嵌套过深或结构无效" }
        }
    }
}
