package io.github.nanomuse.coach

import kotlinx.serialization.Serializable

/** 能力类型决定练法，不用通用分数代替行为证据。 */
@Serializable
enum class CoachKind { JUDGMENT, PERSPECTIVES, ENGLISH, EXPRESSION, LEADERSHIP, EXECUTION, CUSTOM }

/** 单元的行为标准；现实标准必须由用户报告的行动支持。 */
@Serializable
data class CoachCriterion(val id: String, val description: String, val requiresRealAction: Boolean = false,
    val dimension: String = "")

/** 有序课程中的一个单元，保留方法和原始来源。 */
@Serializable
data class CoachUnit(
    val id: String, val title: String, val focus: String, val method: String,
    val criteria: List<CoachCriterion>, val source: String = "", val needsCriteriaReview: Boolean = false,
)

/** 训练开始时保存完整课程快照，后来改课不会改写历史。 */
@Serializable
data class CoachCourse(
    val id: String, val title: String, val place: String, val kind: CoachKind,
    val units: List<CoachUnit>, val version: String, val source: String = "",
    val importProtocol: String = "", val builtInSourceId: String = "", val needsCriteriaReview: Boolean = false,
)

/** 每项能力独立保存进度与暂停状态。 */
@Serializable
data class CoachTrack(
    val course: CoachCourse, val currentUnitId: String = course.units.firstOrNull()?.id.orEmpty(),
    val paused: Boolean = false, val demonstrated: Set<String> = emptySet(),
    val lastPracticedAt: Long = 0, val legacyNote: String = "",
)

/** 回合的提示和情境来源必须与文字一起保留。 */
@Serializable
data class CoachTurn(
    val id: String, val role: String, val text: String, val stage: String,
    val support: String = "none", val context: String = "simulation",
    val originMessageId: String = "", val createdAt: Long = System.currentTimeMillis(),
    val purpose: String = "legacy", val assessmentId: String = "", val dimension: String = "",
    val reviewKind: String = "immediate", val reviewOfSessionId: String = "",
    val sourceInvalidated: Boolean = false,
)

/** 引用只允许指向已经保存的用户原话。 */
@Serializable
data class CoachEvidence(
    val criterionId: String, val turnId: String, val quote: String, val reason: String,
    val met: Boolean, val disputed: Boolean = false,
)

/** 课次保存课程快照；旧版阶段与新版专题教学分别解释，不改写历史。 */
@Serializable
data class CoachSession(
    val id: String, val course: CoachCourse, val unitId: String,
    val stage: String = "setup", val status: String = "active", val draft: String = "",
    val turns: List<CoachTurn> = emptyList(), val evidence: List<CoachEvidence> = emptyList(),
    val pendingTurnId: String? = null, val nextSupport: String = "none",
    val summary: String = "", val revision: Long = 0, val chatSessionId: String = "",
    val requiresCourseReview: Boolean = false,
    val topicId: String = "", val teachingProtocol: String = "legacy", val mode: String = "explain",
    val assessment: CoachAssessment? = null, val startedAt: Long = 0, val endedAt: Long = 0,
    val lessonSummary: CoachLessonSummary? = null,
)

/** 摘要引用已落盘回合，来源消息标识由宿主填写。 */
@Serializable
data class CoachSummarySource(val turnId: String, val messageId: String, val quote: String)

/** 更正与未决假设保留可核对的原文，来源版本由宿主生成。 */
@Serializable
data class CoachLessonSummary(
    val text: String, val courseVersion: String, val sourceRevision: Long,
    val sources: List<CoachSummarySource> = emptyList(),
    val corrections: List<CoachSummarySource> = emptyList(),
    val unresolvedHypotheses: List<CoachSummarySource> = emptyList(),
    val sourceInvalidated: Boolean = false,
)

/** 验证题先保存再作答；延迟间隔由宿主时钟计算，模型只能选择复核对象。 */
@Serializable
data class CoachAssessment(
    val id: String, val promptTurnId: String, val dimension: String,
    val reviewOfSessionId: String = "", val isDelayed: Boolean = false,
)

/** 同一案例专题拥有一条长期聊天，包含多节独立归档的课次。 */
@Serializable
data class CoachTopic(
    val id: String, val courseId: String, val unitId: String, val title: String, val caseText: String,
    val chatSessionId: String = "", val activeSessionId: String? = null,
    val status: String = "active", val createdAt: Long = 0,
    val archiveReason: String = "",
)

/** 理解、应用与延迟复核分别展示，不将旧评分推断为双维度证据。 */
data class CoachTopicProgress(
    val hasUnderstanding: Boolean, val hasApplication: Boolean, val hasDelayedReview: Boolean,
    val isDemonstrated: Boolean,
)

/** 由宿主指定可信聊天范围；模型工具参数不能创建或扩大此范围。 */
data class CoachConversationScope(val chatSessionId: String, val isMain: Boolean = false)

/** 探索草案和正式课程分开，确认绑定精确版本。 */
@Serializable
data class CoachDraft(
    val id: String, val text: String, val course: CoachCourse? = null,
    val revision: Long = 0, val status: String = "exploring",
    val proposedFromMessageId: String = "", val sourceStatus: String = "unverified",
    val activatedCourseId: String? = null,
)

/** 现实任务保留计划变更历史，报告不冒充外部核验。 */
@Serializable
data class CoachAction(
    val id: String, val sessionId: String, val plan: String, val status: String = "planned",
    val planHistory: List<String> = emptyList(), val reports: List<CoachTurn> = emptyList(),
)

/** 一份原子快照包含全部关系，避免课程已出现而单元尚未写完。 */
@Serializable
data class CoachState(
    val schemaVersion: Int = 3, val revision: Long = 0,
    val tracks: List<CoachTrack> = emptyList(), val sessions: List<CoachSession> = emptyList(),
    val drafts: List<CoachDraft> = emptyList(), val actions: List<CoachAction> = emptyList(),
    val operations: Map<String, String> = emptyMap(), val selectedCourseId: String = "expression",
    val topics: List<CoachTopic> = emptyList(),
)

/** 由聊天宿主传入，模型不能自己伪造当前用户消息。 */
data class CoachUserInput(val messageId: String, val text: String, val chatSessionId: String = "")

/** 所有入口共用带版本和重试标识的命令。 */
@Serializable
data class CoachCommand(
    val action: String, val operationId: String, val expectedRevision: Long,
    val targetId: String = "", val text: String = "", val payload: String = "",
)

/** 写入失败明确返回，调用方不能据模型措辞显示成功。 */
data class CoachResult(val success: Boolean, val message: String, val revision: Long, val targetId: String = "")
