package io.github.nanomuse.coach

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.*
import org.junit.Test

/** 验证模型工具不能绕过版本、受控动作及真实用户来源。 */
class CoachAgentBridgeTest {
    private val course = CoachCourse("expression", "表达", "会客厅", CoachKind.EXPRESSION,
        listOf(CoachUnit("1.1", "先问再答", "确认关切", "重试",
            listOf(CoachCriterion("target", "确认关切")))), "v1")
    private val state = CoachState(revision = 7, tracks = listOf(CoachTrack(course)))
    private var received: Pair<CoachCommand, CoachUserInput?>? = null
    private val bridge = CoachAgentBridge({ state }) { command, user ->
        received = command to user
        CoachResult(true, "已保存", 8, command.targetId)
    }

    @Test fun should_reject_command_without_version_or_operation_id() {
        assertFalse(bridge.command("""{"action":"pause_course","targetId":"expression"}""", null).success)
        assertNull(received)
        assertFalse(bridge.command("""{"action":"pause_course","operationId":"one","expectedRevision":7.5}""", null).success)
        assertNull(received)
    }

    @Test fun should_reject_unknown_destructive_and_path_commands() {
        listOf("delete", "file_write", "reset", "advance_all").forEach { action ->
            val result = bridge.command("""{"action":"$action","operationId":"one","expectedRevision":7}""", null)
            assertFalse(result.success)
        }
        assertFalse(bridge.command("""{"action":"pause_course","targetId":"../../state.json","operationId":"one","expectedRevision":7}""", null).success)
        assertNull(received)
    }

    @Test fun should_forward_host_user_identity_and_exact_text_to_service() {
        val user = CoachUserInput("real-message-id", "我会先问你最担心什么", "main-session")
        val result = bridge.command("""{"action":"answer","targetId":"session-1","text":"你最担心什么","operationId":"one","expectedRevision":7,"userMessageId":"fake"}""", user)
        assertTrue(result.success)
        assertSame(user, received!!.second)
        assertEquals("你最担心什么", received!!.first.text)
        assertEquals(7L, received!!.first.expectedRevision)
    }

    @Test fun should_keep_structured_payload_unchanged_for_service_validation() {
        val payload = """{"next":"probe","evidence":[]}"""
        val args = """{"action":"coach_reply","targetId":"session-1","text":"换一个新情境","operationId":"reply-1","expectedRevision":7,"payload":${Json.encodeToString(kotlinx.serialization.serializer<String>(), payload)}}"""
        assertTrue(bridge.command(args, null).success)
        assertEquals(payload, received!!.first.payload)
    }

    @Test fun should_return_bounded_summaries_then_explicit_detail() {
        val many = state.copy(tracks = (1..40).map { CoachTrack(course.copy(id = "course-$it")) })
        val queryBridge = CoachAgentBridge({ many }) { _, _ -> error("查询不能写入") }
        val list = Json.parseToJsonElement(queryBridge.query("""{"kind":"courses","limit":2}""").output).jsonObject
        assertEquals("7", list.getValue("revision").jsonPrimitive.content)
        assertEquals(2, list.getValue("data").jsonArray.size)
        assertFalse(list.getValue("data").jsonArray.first().jsonObject.containsKey("course"))
        val detail = queryBridge.query("""{"kind":"courses","targetId":"course-3"}""")
        assertTrue(detail.success)
        assertTrue(detail.output.contains("确认关切"))
        assertFalse(queryBridge.query("""{"kind":"courses","targetId":"missing"}""").success)
    }

    @Test fun should_report_service_failure_without_claiming_success() {
        val failedBridge = CoachAgentBridge({ state }) { _, _ -> CoachResult(false, "版本已更新，请重新查询", 9) }
        val result = failedBridge.command("""{"action":"pause_course","targetId":"expression","operationId":"one","expectedRevision":7}""", null)
        assertFalse(result.success)
        assertTrue(result.output.contains("版本已更新"))
        assertTrue(result.output.contains("\"revision\":9"))
    }

    @Test fun should_page_summaries_without_disclosing_unrequested_full_history() {
        val many = state.copy(tracks = (1..40).map { CoachTrack(course.copy(id = "course-$it")) })
        val queryBridge = CoachAgentBridge({ many }) { _, _ -> error("查询不能写入") }
        val result = Json.parseToJsonElement(queryBridge.query("""{"kind":"courses","offset":2,"limit":2}""").output).jsonObject
        assertEquals("course-3", result.getValue("data").jsonArray.first().jsonObject.getValue("id").jsonPrimitive.content)
        assertEquals("4", result.getValue("nextOffset").jsonPrimitive.content)
        assertEquals("40", result.getValue("total").jsonPrimitive.content)
    }

    @Test fun should_expose_only_native_controlled_actions_and_flat_parameters() {
        val tools = CoachAgentBridge.definitions()
        assertEquals(listOf("coach_query", "coach_command"), tools.map { it.name })
        val command = tools.last()
        assertTrue(command.required.containsAll(listOf("action", "operationId", "expectedRevision")))
        assertFalse(command.parameters.getValue("action").enumValues!!.contains("delete"))
        assertEquals("string", command.parameters.getValue("payload").type)
    }

    @Test fun should_fail_closed_for_malformed_or_wrongly_typed_arguments() {
        listOf("not json", "[]", "null", """{"action":"pause_course","operationId":"a","expectedRevision":"7"}""")
            .forEach { assertFalse(bridge.command(it, null).success) }
        assertNull(received)
    }

    @Test fun should_limitQueriesAndCommands_toHostBoundTopic() {
        val topic = CoachTopic("topic-a", course.id, "1.1", "案例甲", "甲的案例", chatSessionId = "chat-a")
        val other = topic.copy(id = "topic-b", title = "案例乙", chatSessionId = "chat-b")
        val scopedState = state.copy(topics = listOf(topic, other), sessions = listOf(
            CoachSession("lesson-a", course, "1.1", topicId = "topic-a"),
            CoachSession("lesson-b", course, "1.1", topicId = "topic-b")))
        val scoped = CoachAgentBridge({ scopedState }, CoachConversationScope("chat-a")) { command, user ->
            received = command to user
            CoachResult(true, "已保存", 8)
        }
        val topics = Json.parseToJsonElement(scoped.query("""{"kind":"topics"}""").output).jsonObject
        assertEquals(1, topics.getValue("data").jsonArray.size)
        assertFalse(scoped.query("""{"kind":"sessions","targetId":"lesson-b"}""").success)
        assertFalse(scoped.command("""{"action":"save_input","operationId":"x","expectedRevision":7,"targetId":"lesson-b"}""", null).success)
        assertNull(received)
        assertFalse(scoped.command("""{"action":"bind_topic","operationId":"x","expectedRevision":7,"targetId":"topic-a"}""", null).success)
        val prompt = CoachAgentBridge.conversationPrompt(scopedState, "chat-a")
        assertTrue(prompt.contains("topic-a"))
        assertFalse(prompt.contains("topic-b"))
        assertFalse(prompt.contains("案例乙"))
        assertEquals("", CoachAgentBridge.conversationPrompt(scopedState, "ordinary-chat"))
    }
}
