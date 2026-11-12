package io.github.nanomuse.coach

import com.openminis.app.data.model.AgentToolDefinition
import com.openminis.app.data.model.AgentToolParam
import com.openminis.app.provider.ToolJsonRepair
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** 验证模型参数经过通用修复器后仍遵守教练协议与原生类型声明。 */
class CoachToolJsonRepairTest {
    @Test fun should_forwardIntegerRevision_when_repairedBeforeCoachBridge() {
        val arguments = JSONObject("""{"action":"new_draft","operationId":"create-one","expectedRevision":7,"text":"我想练习表达"}""")
        val repairs = ToolJsonRepair.repair(CoachAgentBridge.COMMAND, arguments, null, CoachAgentBridge.definitions())
        var received: CoachCommand? = null
        val bridge = CoachAgentBridge({ CoachState(revision = 7) }) { command, _ ->
            received = command
            CoachResult(true, "Saved", 8, "draft-one")
        }

        assertTrue(bridge.command(arguments.toString(), CoachUserInput("user-one", "我想练习表达")).success)
        assertEquals(7L, received!!.expectedRevision)
        assertFalse(repairs.contains("type-coerce:expectedRevision"))
        assertTrue(arguments.get("expectedRevision") is Number)
    }

    @Test fun should_preserveNativeTypes_when_schemaDeclaresNonStringFields() {
        val types = mapOf("count" to "integer", "ratio" to "number", "enabled" to "boolean",
            "options" to "object", "items" to "array")
        val definition = AgentToolDefinition("native", "原生类型测试",
            types.mapValues { AgentToolParam(it.value, "测试") }, types.keys.toList())
        val arguments = JSONObject("""{"count":3,"ratio":0.5,"enabled":true,"options":{"a":1},"items":[1,2]}""")

        assertTrue(ToolJsonRepair.repair("native", arguments, null, listOf(definition)).isEmpty())
        assertTrue(arguments.get("count") is Number)
        assertTrue(arguments.get("ratio") is Number)
        assertTrue(arguments.get("enabled") is Boolean)
        assertTrue(arguments.get("options") is JSONObject)
        assertTrue(arguments.get("items") is JSONArray)
    }

    @Test fun should_keepStringCoercion_when_schemaRequiresText() {
        val definition = AgentToolDefinition("text", "文本修复测试",
            mapOf("value" to AgentToolParam("string", "文本")), listOf("value"))
        val arguments = JSONObject("""{"value":123}""")

        assertEquals(listOf("type-coerce:value"),
            ToolJsonRepair.repair("text", arguments, null, listOf(definition)))
        assertEquals("123", arguments.get("value"))
    }

    @Test fun should_rejectStringRevision_when_modelActuallySendsWrongType() {
        val arguments = JSONObject("""{"action":"new_draft","operationId":"create-one","expectedRevision":"7","text":"表达"}""")
        ToolJsonRepair.repair(CoachAgentBridge.COMMAND, arguments, null, CoachAgentBridge.definitions())
        val bridge = CoachAgentBridge({ CoachState(revision = 7) }) { _, _ ->
            error("错误类型不能进入命令服务")
        }

        assertFalse(bridge.command(arguments.toString(), null).success)
        assertEquals("7", arguments.get("expectedRevision"))
    }

    @Test fun should_preserveTruncationAndFuzzyRepair_when_integerFieldIsRecovered() {
        val definition = AgentToolDefinition("native", "恢复测试",
            mapOf("count" to AgentToolParam("integer", "数量")), listOf("count"))
        val arguments = JSONObject()
        val repairs = ToolJsonRepair.repair("native", arguments, """{"coun":3""", listOf(definition))

        assertTrue(repairs.any { it.startsWith("truncation+") })
        assertTrue(repairs.contains("fuzzy:coun->count"))
        assertTrue(arguments.get("count") is Number)
        assertEquals(3, arguments.getInt("count"))
    }
}
