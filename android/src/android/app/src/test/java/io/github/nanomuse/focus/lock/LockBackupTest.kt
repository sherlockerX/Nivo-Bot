package io.github.nanomuse.focus.lock

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** 验证锁机配置备份的账号边界、停用恢复和有界纯JSON解析。 */
class LockBackupTest {
    private val sourceOwner = "source-owner"
    private val targetOwner = "target-owner"
    private val plan = LockPlan(
        id = "study", name = "晚间学习", days = setOf(1, 3, 7),
        ranges = listOf(TimeRange(1380, 60), TimeRange(480, 540)),
        title = "阅读", taskId = "task-1", ownerKey = sourceOwner, revision = 3L
    )
    private val whitelist = setOf("test.reader", "test.dictionary")

    /** 导出只保存配置，恢复后必须重新启用计划且归属目标账号。 */
    @Test
    fun should_roundTripDisabledConfiguration_when_backupContainsEnabledPlans() {
        val encoded = LockBackup.encode(sourceOwner, listOf(plan), whitelist)
        val restored = LockBackup.decode(encoded, targetOwner, false)
        assertEquals(listOf(plan.copy(ownerKey = targetOwner, isEnabled = false)), restored.plans)
        assertEquals(whitelist, restored.whitelist)
        assertEquals(targetOwner, restored.ownerKey)
        assertTrue(plan.isEnabled)
    }

    /** FocusStore可直接把配置对象嵌入现有备份，导出保留启用状态。 */
    @Test
    fun should_exportConfigurationObject_when_focusEnvelopeEmbedsLockSettings() {
        val json = LockBackup.encode(listOf(plan), whitelist)
        assertTrue(row(json).getBoolean("isEnabled"))
        assertEquals("nanomuse-focus-lock", json.getString("format"))
    }

    /** LockStore从外层备份取出对象后绑定当前账号并强制停用。 */
    @Test
    fun should_decodeConfigurationObject_when_storeImportsEmbeddedSettings() {
        val restored = LockBackup.decode(document(), targetOwner)
        assertEquals(listOf(plan.copy(ownerKey = targetOwner, isEnabled = false)), restored.plans)
        assertEquals(whitelist, restored.whitelist)
    }

    /** 对象导入入口同样不能绕过活动锁。 */
    @Test
    fun should_rejectConfigurationObject_when_storeReportsActiveRun() {
        assertThrows(IllegalStateException::class.java) {
            LockBackup.decode(document(), targetOwner, true)
        }
    }

    /** 对象导出同样必须验证账号集合，空配置仍可导出。 */
    @Test
    fun should_validateOwners_when_exportingConfigurationObject() {
        assertRejected { LockBackup.encode(listOf(plan, plan.copy(id = "other", ownerKey = targetOwner)), whitelist) }
        assertEquals(0, LockBackup.encode(emptyList(), emptySet()).getJSONArray("plans").length())
    }

    /** 离线本地账号使用空字符串身份，字符串备份必须正常往返。 */
    @Test
    fun should_roundTripLocalOwner_when_accountKeyIsEmpty() {
        val localPlan = plan.copy(ownerKey = "")
        val restored = LockBackup.decode(LockBackup.encode("", listOf(localPlan), whitelist), "", false)
        assertEquals("", restored.ownerKey)
        assertEquals(listOf(localPlan.copy(isEnabled = false)), restored.plans)
    }

    /** 本地账号对象接口可导出并恢复，也可明确导入到另一个当前账号。 */
    @Test
    fun should_roundTripLocalObject_when_accountKeyIsEmpty() {
        val localPlan = plan.copy(ownerKey = "")
        val json = LockBackup.encode(listOf(localPlan), whitelist)
        assertEquals(listOf(localPlan.copy(isEnabled = false)), LockBackup.decode(json, "").plans)
        assertEquals(targetOwner, LockBackup.decode(json, targetOwner).plans.single().ownerKey)
    }

    /** 本地与云账号同时混入时仍须拒绝，空键不代表任意账号。 */
    @Test
    fun should_rejectMixedLocalAndCloudOwners_when_exportContainsBoth() {
        assertRejected { LockBackup.encode(listOf(plan, plan.copy(id = "local", ownerKey = "")), whitelist) }
    }

    /** 原来停用的计划不会在恢复时意外启用。 */
    @Test
    fun should_keepDisabledPlan_when_sourceWasAlreadyDisabled() {
        val restored = LockBackup.decode(
            LockBackup.encode(sourceOwner, listOf(plan.copy(isEnabled = false)), emptySet()), targetOwner, false
        )
        assertFalse(restored.plans.single().isEnabled)
    }

    /** 空配置是合法备份，不创建计划或运行记录。 */
    @Test
    fun should_roundTripEmptyConfiguration_when_noSettingsExist() {
        val restored = LockBackup.decode(LockBackup.encode(sourceOwner, emptyList(), emptySet()), targetOwner, false)
        assertEquals(emptyList<LockPlan>(), restored.plans)
        assertEquals(emptySet<String>(), restored.whitelist)
    }

    /** 空可选值必须保持为空，而不是变成字符串null。 */
    @Test
    fun should_preserveNullOptionalFields_when_planHasNoLinkedTaskOrTitle() {
        val input = plan.copy(title = null, taskId = null)
        val restored = LockBackup.decode(LockBackup.encode(sourceOwner, listOf(input), whitelist), targetOwner, false)
        assertEquals(input.copy(ownerKey = targetOwner, isEnabled = false), restored.plans.single())
    }

    /** 明确关闭白名单与空草稿星期时段仍保持配置语义。 */
    @Test
    fun should_keepDraftAndStrictSettings_when_optionalCollectionsAreEmpty() {
        val input = plan.copy(days = emptySet(), ranges = emptyList(), usesWhitelist = false)
        val restored = LockBackup.decode(LockBackup.encode(sourceOwner, listOf(input), whitelist), targetOwner, false)
        assertEquals(input.copy(ownerKey = targetOwner, isEnabled = false), restored.plans.single())
    }

    /** 备份不携带源账户身份和会话数据。 */
    @Test
    fun should_exportOnlyConfigurationFields_when_snapshotIsSerialized() {
        val json = JSONObject(LockBackup.encode(sourceOwner, listOf(plan), whitelist))
        assertEquals(setOf("format", "version", "plans", "whitelist"), json.keySet())
        assertEquals("nanomuse-focus-lock", json.getString("format"))
        assertEquals(1, json.getInt("version"))
        assertFalse(json.toString().contains(sourceOwner))
        assertFalse(json.getJSONArray("plans").getJSONObject(0).has("ownerKey"))
    }

    /** 导出不能混入另一个账号的计划。 */
    @Test
    fun should_rejectExport_when_planOwnerDiffers() {
        assertRejected { LockBackup.encode(sourceOwner, listOf(plan.copy(ownerKey = targetOwner)), whitelist) }
    }

    /** 空账户键不能成为持久化备份身份。 */
    @Test
    fun should_rejectBlankOwner_when_exportingOrImporting() {
        assertRejected { LockBackup.encode(" ", emptyList(), emptySet()) }
        assertRejected { LockBackup.decode(document().toString(), " ", false) }
    }

    /** 活动锁存在时，在解析任何输入之前统一拒绝恢复。 */
    @Test
    fun should_rejectBeforeParsing_when_activeRunExists() {
        val error = assertThrows(IllegalStateException::class.java) {
            LockBackup.decode("not-json", targetOwner, true)
        }
        assertEquals("focus_locked", error.message)
    }

    /** 活动锁不能通过导入空备份清除配置。 */
    @Test
    fun should_rejectEmptyRestore_when_activeRunExists() {
        assertThrows(IllegalStateException::class.java) {
            LockBackup.decode(document().put("plans", JSONArray()).toString(), targetOwner, true)
        }
    }

    /** 任何运行记录载荷都必须拒绝，不能恢复已结束或活动会话。 */
    @Test
    fun should_rejectRunPayload_when_documentContainsSessionState() {
        for (field in listOf("runs", "activeRun", "focus_lock_runs", "sessions", "completedOccurrenceIds")) {
            assertRejected { LockBackup.decode(document().put(field, JSONArray()).toString(), targetOwner, false) }
        }
    }

    /** 文件内容不能指定写入账号。 */
    @Test
    fun should_rejectEmbeddedOwner_when_payloadTriesToChooseTargetAccount() {
        assertRejected { LockBackup.decode(document().put("ownerKey", sourceOwner).toString(), targetOwner, false) }
        val json = document()
        row(json).put("ownerKey", sourceOwner)
        assertRejected { LockBackup.decode(json.toString(), targetOwner, false) }
    }

    /** 不兼容格式和版本不能按当前契约导入。 */
    @Test
    fun should_rejectUnsupportedEnvelope_when_formatOrVersionDiffers() {
        for (json in listOf(document().put("format", "nanomuse-todo"), document().put("version", 2),
            document().put("version", "1"), document().put("version", 1.5))) {
            assertRejected { LockBackup.decode(json.toString(), targetOwner, false) }
        }
    }

    /** 配置集合缺失、错误类型或尾随文档必须被拒绝。 */
    @Test
    fun should_rejectMalformedDocument_when_shapeOrTrailingContentIsInvalid() {
        val missingPlans = document().also { it.remove("plans") }
        for (text in listOf("[]", "null", "{", document().toString() + "{}", missingPlans.toString(),
            document().put("plans", JSONObject()).toString(), document().put("whitelist", "test.reader").toString())) {
            assertRejected { LockBackup.decode(text, targetOwner, false) }
        }
    }

    /** 相同ID重复出现不能在恢复中变成最后一项覆盖前一项。 */
    @Test
    fun should_rejectDuplicatePlanIds_when_exportingOrImporting() {
        assertRejected { LockBackup.encode(sourceOwner, listOf(plan, plan), whitelist) }
        val json = document()
        json.getJSONArray("plans").put(JSONObject(row(json).toString()))
        assertRejected { LockBackup.decode(json.toString(), targetOwner, false) }
    }

    /** 模型数字必须为真实整数，禁止字符串和小数强制转换。 */
    @Test
    fun should_rejectCoercedNumbers_when_calendarOrRevisionValuesAreMalformed() {
        for (value in listOf<Any>("3", 1.5, 0L, -1L)) {
            val json = document()
            row(json).put("revision", value)
            assertRejected { LockBackup.decode(json.toString(), targetOwner, false) }
        }
        val json = document()
        row(json).getJSONArray("ranges").getJSONObject(0).put("startMinute", "1380")
        assertRejected { LockBackup.decode(json.toString(), targetOwner, false) }
    }

    /** 布尔配置不能从其他JSON类型隐式转换。 */
    @Test
    fun should_rejectCoercedBooleans_when_settingsAreNotBoolean() {
        for (field in listOf("isEnabled", "usesWhitelist")) {
            val json = document()
            row(json).put(field, "true")
            assertRejected { LockBackup.decode(json.toString(), targetOwner, false) }
        }
    }

    /** 损坏的星期、分钟和重复星期不能悄悄规范化。 */
    @Test
    fun should_rejectInvalidCalendar_when_weekdaysOrMinutesAreInvalid() {
        for (days in listOf(listOf(0), listOf(8), listOf(1, 1), listOf("1"))) {
            val json = document()
            row(json).put("days", JSONArray(days))
            assertRejected { LockBackup.decode(json.toString(), targetOwner, false) }
        }
        val json = document()
        row(json).getJSONArray("ranges").getJSONObject(0).put("endMinute", 1440)
        assertRejected { LockBackup.decode(json.toString(), targetOwner, false) }
    }

    /** 重复时段不能使导入产生重复启动身份。 */
    @Test
    fun should_rejectDuplicateRanges_when_planRepeatsSameTimeRange() {
        val json = document()
        val ranges = row(json).getJSONArray("ranges")
        ranges.put(JSONObject(ranges.getJSONObject(0).toString()))
        assertRejected { LockBackup.decode(json.toString(), targetOwner, false) }
    }

    /** 无效白名单包名、非字符串和重复包名不能进入数据库。 */
    @Test
    fun should_rejectInvalidWhitelist_when_packagesAreMalformedOrDuplicated() {
        for (packages in listOf(listOf("test.reader", "test.reader"), listOf("bad package"),
            listOf(".bad"), listOf(42), listOf("x".repeat(256)))) {
            assertRejected {
                LockBackup.decode(document().put("whitelist", JSONArray(packages)).toString(), targetOwner, false)
            }
        }
    }

    /** 字段长度在导出和导入采用同一边界。 */
    @Test
    fun should_rejectOversizedFields_when_planTextExceedsLimits() {
        assertRejected { LockBackup.encode(sourceOwner, listOf(plan.copy(name = "x".repeat(501))), whitelist) }
        val json = document()
        row(json).put("taskId", "x".repeat(201))
        assertRejected { LockBackup.decode(json.toString(), targetOwner, false) }
    }

    /** 不合法字段类型和未知字段不能被忽略后进入存储。 */
    @Test
    fun should_rejectInvalidPlanFields_when_shapeIsUnexpected() {
        for ((field, value) in listOf("name" to 42, "taskId" to 42, "run" to JSONObject())) {
            val json = document()
            row(json).put(field, value)
            assertRejected { LockBackup.decode(json.toString(), targetOwner, false) }
        }
    }

    /** 集合数量在大对象映射前验证，导出不生成无法导入的备份。 */
    @Test
    fun should_rejectExcessiveCollections_when_limitsAreExceeded() {
        assertRejected { LockBackup.encode(sourceOwner, List(1001) { plan.copy(id = "plan-$it") }, whitelist) }
        assertRejected { LockBackup.encode(sourceOwner, emptyList(), (0..1000).map { "test.app$it" }.toSet()) }
        val json = document()
        row(json).put("ranges", JSONArray((0..64).map { JSONObject().put("startMinute", it).put("endMinute", it + 1) }))
        assertRejected { LockBackup.decode(json.toString(), targetOwner, false) }
    }

    /** UTF-8大小受限，中文内容不能利用字符数绕过字节上限。 */
    @Test
    fun should_rejectOversizedUtf8Document_when_characterCountIsBelowLimit() {
        val text = document().put("padding", "中".repeat(400_000)).toString()
        assertTrue(text.length < 1_000_000)
        assertRejected { LockBackup.decode(text, targetOwner, false) }
    }

    /** 深层未知载荷在进入JSON递归解析前拒绝。 */
    @Test
    fun should_rejectDeepNesting_when_untrustedJsonExceedsStructuralLimit() {
        val text = "{\"payload\":" + "[".repeat(1000) + "0" + "]".repeat(1000) + "}"
        assertRejected { LockBackup.decode(text, targetOwner, false) }
    }

    /** 文本内的括号和转义引号不属于真实JSON层级。 */
    @Test
    fun should_preserveEscapedText_when_contentContainsStructuralCharacters() {
        val input = plan.copy(name = "[阅读] {练习} \\\"quoted\\\"")
        val restored = LockBackup.decode(LockBackup.encode(sourceOwner, listOf(input), whitelist), targetOwner, false)
        assertEquals(input.name, restored.plans.single().name)
    }

    /** 外层专注备份只提取锁机配置，不恢复活动计时或历史区间。 */
    @Test
    fun should_extractOnlyLockConfiguration_when_focusEnvelopeIsValid() {
        val json = focusDocument().put("sessions", JSONArray().put(JSONObject().put("status", "running")))
            .put("spans", JSONArray())
        val lock = LockBackup.parseFocusConfiguration(json.toString())
        assertEquals("nanomuse-focus-lock", lock.getString("format"))
        assertFalse(lock.has("sessions"))
        assertTrue(row(lock).getBoolean("isEnabled"))
    }

    /** 外层版本必须是真实整数1，不能截断小数或接受字符串。 */
    @Test
    fun should_rejectCoercedOuterVersion_when_focusVersionHasWrongTypeOrValue() {
        for (version in listOf<Any>("1", 1.5, 0, 2, JSONObject.NULL)) {
            assertRejected { LockBackup.parseFocusConfiguration(focusDocument().put("version", version).toString()) }
        }
    }

    /** 外层格式、配置类型以及缺失配置必须在存储前拒绝。 */
    @Test
    fun should_rejectInvalidFocusEnvelope_when_formatOrLockShapeIsWrong() {
        val missingLock = focusDocument().also { it.remove("lock") }
        for (json in listOf(focusDocument().put("format", "nanomuse-todo"),
            focusDocument().put("lock", JSONArray()), missingLock)) {
            assertRejected { LockBackup.parseFocusConfiguration(json.toString()) }
        }
    }

    /** 尾随第二个文档和NUL截断不能绕过完整输入检查。 */
    @Test
    fun should_rejectTrailingPayload_when_focusDocumentHasExtraContent() {
        for (suffix in listOf("{}", "[]", " trailing", "\u0000{}")) {
            assertRejected { LockBackup.parseFocusConfiguration(focusDocument().toString() + suffix) }
        }
    }

    /** 外层解析前限制深度，避免未知字段触发JSON递归栈耗尽。 */
    @Test
    fun should_rejectDeepOuterPayload_when_focusEnvelopeHasUnknownNestedData() {
        val text = "{\"padding\":" + "[".repeat(1000) + "0" + "]".repeat(1000) + "}"
        assertRejected { LockBackup.parseFocusConfiguration(text) }
    }

    /** 外层按UTF-8字节限制8MB，不能仅计算中文字符个数。 */
    @Test
    fun should_rejectOversizedOuterUtf8_when_textLengthIsBelowEightMillion() {
        val text = focusDocument().put("padding", "中".repeat(2_666_667)).toString()
        assertTrue(text.length < 8_000_000)
        assertRejected { LockBackup.parseFocusConfiguration(text) }
    }

    /** 恰好8MB仍是合法输入，多一个字节必须拒绝。 */
    @Test
    fun should_acceptExactOuterByteLimit_when_documentIsOtherwiseValid() {
        val json = focusDocument().put("padding", "")
        val remaining = 8_000_000 - json.toString().toByteArray(Charsets.UTF_8).size
        val exact = json.put("padding", "a".repeat(remaining)).toString()
        assertEquals("nanomuse-focus-lock", LockBackup.parseFocusConfiguration(exact).getString("format"))
        assertRejected { LockBackup.parseFocusConfiguration(exact + " ") }
    }

    /** 外层允许正常文本中的括号和转义引号，不误算为嵌套。 */
    @Test
    fun should_acceptStructuralText_when_focusEnvelopeContainsQuotedBrackets() {
        val json = focusDocument().put("note", "[{}] \\\"quoted\\\"")
        assertEquals("nanomuse-focus-lock", LockBackup.parseFocusConfiguration(json.toString()).getString("format"))
    }

    /** 不完整JSON和非对象顶层统一返回参数错误。 */
    @Test
    fun should_rejectMalformedOuterJson_when_documentCannotBeParsed() {
        for (text in listOf("[", "null", "[]", "not-json", "{")) {
            assertRejected { LockBackup.parseFocusConfiguration(text) }
        }
    }

    /** 合并后完整配置必须校验实际字节数，数量合格也可能超过备份容量。 */
    @Test
    fun should_rejectMergedEncodedSize_when_individualBatchesFitByteLimit() {
        val first = (0 until 500).map { plan.copy(id = "first-$it", name = "中".repeat(500)) }
        val second = (0 until 500).map { plan.copy(id = "second-$it", name = "中".repeat(500)) }
        LockBackup.encode(first, emptySet())
        LockBackup.encode(second, emptySet())
        assertRejected { LockBackup.encode(first + second, emptySet()) }
    }

    private fun focusDocument(): JSONObject = JSONObject().put("format", "nanomuse-focus").put("version", 1)
        .put("lock", document())

    private fun document(): JSONObject = JSONObject().put("format", "nanomuse-focus-lock").put("version", 1)
        .put("plans", JSONArray().put(JSONObject().put("id", plan.id).put("name", plan.name)
            .put("days", JSONArray(plan.days.toList())).put("ranges", JSONArray(plan.ranges.map {
                JSONObject().put("startMinute", it.startMinute).put("endMinute", it.endMinute)
            })).put("isEnabled", true).put("usesWhitelist", true).put("title", plan.title)
            .put("taskId", plan.taskId).put("revision", plan.revision)))
        .put("whitelist", JSONArray(whitelist.toList()))

    private fun row(json: JSONObject): JSONObject = json.getJSONArray("plans").getJSONObject(0)

    private fun assertRejected(action: () -> Any?) {
        assertThrows(IllegalArgumentException::class.java) { action() }
    }
}
