package io.github.nanomuse.coach

import android.content.Context
import io.github.nanomuse.growth.GrowthStore
import java.io.File
import java.security.MessageDigest

/** 只读导入已安装课程；六门内置课程可从随应用提供的提纲回退。 */
object CoachCurriculumRepository {
    private val UNIT_LINE = Regex("""^\s*-\s+(\d+\.\d+(?:\.\d+)*)[ \t]+(.+?)\s*$""")
    private val TRAILING_REFERENCE = Regex("""\s*[（(]([^）)]*)[）)]\s*$""")
    private val FRAMEWORK_REFERENCE = Regex("""(?:[A-H][ A-H、,]*|全部|B\d+(?:\s+B\d+)*)""")
    private const val SOURCE_LIMIT =
        "书目与理论是原课程引用，尚未重新核验；未提供原文时不编造书中内容、原话、案例或研究结论。"

    private val BUILT_IN_COURSES = listOf(
        BuiltInCourse("principles", CoachKind.JUDGMENT, "原则与判断", "决策书房"),
        BuiltInCourse("lenses", CoachKind.PERSPECTIVES, "多视角分析", "圆桌讨论室"),
        BuiltInCourse("english", CoachKind.ENGLISH, "英语表达", "街角交流室"),
        BuiltInCourse("expression", CoachKind.EXPRESSION, "表达力", "沟通会客厅"),
        BuiltInCourse("leadership", CoachKind.LEADERSHIP, "领导力", "协作工作坊"),
        BuiltInCourse("habits", CoachKind.EXECUTION, "习惯与执行力", "行动工作室"),
    )

    /** 读取课程，不初始化、迁移或改写旧成长记录。 */
    fun load(context: Context): List<CoachCourse> {
        val tracks = GrowthStore.state.value.tracks
        val builtInIds = BUILT_IN_COURSES.map { it.id }.toSet()
        val builtInCourses = BUILT_IN_COURSES.map { definition ->
            val installedSkill = tracks.firstOrNull { it.id == definition.id }?.skill
                ?: "growth-${definition.id}"
            val text = installedText(context, installedSkill)
                ?: bundledText(context, "growth-${definition.id}")
            parse(definition.id, definition.kind, text.orEmpty())
        }
        val customCourses = tracks.filter { it.id !in builtInIds }.map { track ->
            val course = parse(track.id, CoachKind.CUSTOM, installedText(context, track.skill).orEmpty())
            course.copy(title = track.title?.takeIf { it.isNotBlank() } ?: course.title)
        }
        return builtInCourses + customCourses
    }

    /** 按原文件顺序解析单元，保留全文与每个单元的原始行作为可核对来源。 */
    fun parse(id: String, kind: CoachKind, text: String): CoachCourse {
        val lines = curriculumLines(text)
        val definition = BUILT_IN_COURSES.firstOrNull { it.id == id.removePrefix("growth-") }
        val title = lines.firstOrNull { it.startsWith("# ") }?.removePrefix("# ")?.trim()
            ?.takeIf { it.isNotEmpty() } ?: definition?.title ?: id.ifBlank { "自定义课程" }
        val units = lines.mapNotNull { parseUnit(it, kind, definition?.id.orEmpty()) }
        return CoachCourse(
            id = id,
            title = title,
            place = definition?.place ?: "自定义课程",
            kind = kind,
            units = units,
            version = listOfNotNull(declaredVersion(text), contentVersion(text), CoachBuiltInUnits.PROTOCOL).joinToString("+"),
            source = text,
            importProtocol = CoachBuiltInUnits.PROTOCOL,
            builtInSourceId = definition?.id?.takeIf { isUnchangedBuiltIn(it, lines) }.orEmpty(),
            needsCriteriaReview = units.isEmpty() || units.any { it.needsCriteriaReview },
        )
    }

    private fun installedText(context: Context, skill: String): String? {
        if (skill.isBlank() || '/' in skill || '\\' in skill || ':' in skill || ".." in skill) return null
        return runCatching {
            val root = File(context.filesDir, "minis-global/skills").canonicalFile
            val source = File(File(root, skill), "SKILL.md").canonicalFile
            source.takeIf { it.toPath().startsWith(root.toPath()) && it.isFile }
                ?.readText(Charsets.UTF_8)
        }.getOrNull()
    }

    private fun bundledText(context: Context, skill: String): String? = runCatching {
        context.assets.open("preset/skills/$skill/SKILL.md").bufferedReader(Charsets.UTF_8).use { it.readText() }
    }.getOrNull()

    private fun curriculumLines(text: String): List<String> {
        val output = mutableListOf<String>()
        var fence: Char? = null
        var fenceLength = 0
        var isFrontMatter = false
        text.removePrefix("\uFEFF").lineSequence().forEachIndexed { index, line ->
            val trimmed = line.trimStart()
            when {
                index == 0 && trimmed.trimEnd() == "---" -> isFrontMatter = true
                isFrontMatter -> if (trimmed.trimEnd() == "---") isFrontMatter = false
                fence != null -> {
                    val marker = trimmed.takeWhile { it == fence }
                    if (marker.length >= fenceLength && trimmed.drop(marker.length).isBlank()) fence = null
                }
                trimmed.startsWith("```") || trimmed.startsWith("~~~") -> {
                    fence = trimmed.first()
                    fenceLength = trimmed.takeWhile { it == fence }.length
                }
                else -> output += line
            }
        }
        return output
    }

    private fun isUnchangedBuiltIn(id: String, lines: List<String>): Boolean {
        val units = lines.mapNotNull { line -> UNIT_LINE.matchEntire(line)?.let { it.groupValues[1] to line } }
        return units.map { it.first } == CoachBuiltInUnits.unitIds(id) && units.isNotEmpty() &&
            units.all { (unitId, source) -> CoachBuiltInUnits.target(id, unitId, source) != null }
    }

    private fun parseUnit(line: String, kind: CoachKind, courseId: String): CoachUnit? {
        val match = UNIT_LINE.matchEntire(line) ?: return null
        val id = match.groupValues[1]
        val original = match.groupValues[2]
        val separator = original.indexOfFirst { it == '：' || it == ':' }
        val heading = if (separator >= 0) original.substring(0, separator).trim() else original.trim()
        val title = unitTitle(heading)
        if (title.isBlank()) return null
        val description = if (separator >= 0) original.substring(separator + 1).trim() else ""
        val focus = description.ifBlank { title }
        val segments = description.split('；', ';').map { it.trim() }.filter { it.isNotEmpty() }
        val builtIn = CoachBuiltInUnits.target(courseId, id, line)
        val explicit = explicitTarget(title, segments)
        val target = builtIn?.let { UnitTarget(it.principle, it.scenario, it.practice, it.requiresRealAction, title) }
            ?: explicit ?: UnitTarget(
            title = title,
            principle = segments.firstOrNull() ?: title,
            // 未标字段的旧自定义提纲不猜测分号语义；全文仍保留供审阅。
            scenario = "",
            practice = description.ifBlank { title },
            requiresRealAction = false,
        )
        return CoachUnit(
            id = id,
            title = title,
            focus = focus,
            method = teachingMethod(kind, description.isBlank()),
            criteria = criteria(kind, target),
            source = line,
            needsCriteriaReview = builtIn == null && explicit == null,
        )
    }

    private fun explicitTarget(title: String, segments: List<String>): UnitTarget? {
        val pairs = segments.mapNotNull { value ->
            val index = value.indexOfFirst { it == '：' || it == ':' }
            if (index < 0) null else value.substring(0, index).trim() to value.substring(index + 1).trim()
        }
        if (pairs.map { it.first }.distinct().size != pairs.size) return null
        val fields = pairs.toMap()
        val principle = fields["原理"] ?: return null
        val scenario = fields["情景"] ?: return null
        val practice = fields["实践"] ?: return null
        val realAction = fields["现实行动"] ?: return null
        if (principle.isBlank() || scenario.isBlank() || practice.isBlank()) return null
        if (realAction !in setOf("是", "否")) return null
        return UnitTarget(principle, scenario, practice, realAction == "是", title)
    }

    private fun unitTitle(heading: String): String {
        val reference = TRAILING_REFERENCE.find(heading) ?: return heading
        val contents = reference.groupValues[1].trim()
        val isReference = '；' in contents || ';' in contents || FRAMEWORK_REFERENCE.matches(contents)
        return if (isReference) heading.substring(0, reference.range.first).trim() else heading
    }

    private fun teachingMethod(kind: CoachKind, isOutlineOnly: Boolean): String {
        val method = when (kind) {
            CoachKind.JUDGMENT -> "先解释本单元的判断方法，再用情境追问区分事实、推断和结果；提交理由与可推翻判断的证据后，再给针对性反馈。"
            CoachKind.PERSPECTIVES -> "先解释本单元的视角或模型，用图、对照或不同预测检查解释的边界；让学习者自行比较，再追问和修订。"
            CoachKind.ENGLISH -> "用中文说明任务，让学习者先交自己的英文；只纠正与本单元目标相关的少数问题，说明原因，并要求重新表达。语音只有转写时不能评价发音。"
            CoachKind.EXPRESSION -> "先确定听众和目的，进行角色对话或短文演练；让学习者先说出关键话语，再从对方能否理解、回应和行动来修订。"
            CoachKind.LEADERSHIP -> "从本单元的合作情境辨认人、约束和责任，先演练决定或对话，再做低风险的合作实践，并根据实际反馈复盘。"
            CoachKind.EXECUTION -> "先诊断本单元的具体卡点，制定可开始的最小动作，再执行并报告实际发生的行为、次数和障碍；计划不能代替行动报告。"
            CoachKind.CUSTOM -> "只依据本单元已提供的目标和材料，先说明概念，再让学习者完成自己的例子或任务，针对产出追问并修订。"
        }
        val outlineLimit = if (isOutlineOnly) "该单元未提供详细目标或材料，先围绕标题澄清学习者的问题，不补写不存在的课程内容。" else ""
        return "$method$outlineLimit$SOURCE_LIMIT"
    }

    private fun criteria(kind: CoachKind, target: UnitTarget): List<CoachCriterion> {
        val practice = target.practice.ifBlank { "围绕「${target.title}」提交自己的解释或示例，并标明仍需补充的材料" }
        val practiceDescription = if (target.requiresRealAction) {
            "完成「${target.title}」的任务：$practice。报告实际做了什么、发生时间或次数、观察结果与障碍；仅有计划不能通过此项。"
        } else {
            "提交「${target.title}」要求的产出：$practice。区分情境演练、本人实际完成的行动与尚未发生的计划。"
        }
        return listOf(
            CoachCriterion("understanding", "用自己的话准确说明「${target.title}」的具体目标：${target.principle}"),
            CoachCriterion("application", applicationCriterion(kind, target)),
            CoachCriterion("practice", practiceDescription, requiresRealAction = target.requiresRealAction),
        )
    }

    private fun applicationCriterion(kind: CoachKind, target: UnitTarget): String = with(target) {
        if (scenario.isBlank()) return "「$title」未提供独立情景；先与学习者确认一个可演练的情景，再应用「$principle」，不要把实践任务冒充为情景。"
        when (kind) {
            CoachKind.JUDGMENT -> "在「$scenario」中应用「$title」，写出可核对的事实、判断理由和会使判断改变的证据。"
            CoachKind.PERSPECTIVES -> "围绕「$title」分析「$scenario」，比较解释的预测和适用边界，用本单元的模型说明关系。"
            CoachKind.ENGLISH -> "针对「$scenario」提供自己的英文原文，落实「$title」的要求：$principle，并能解释修改带来的含义或语用变化。"
            CoachKind.EXPRESSION -> "在「$scenario」中说出或写出体现「$title」的关键话语，依据「$principle」检查听众能否理解与回应。"
            CoachKind.LEADERSHIP -> "针对「$scenario」写清合作对象、约束和下一步，说明「$title」的要求「$principle」如何改变做法。"
            CoachKind.EXECUTION -> "针对「$scenario」把「$title」落到触发条件与可以开始的动作，说明方案如何满足「$principle」。"
            CoachKind.CUSTOM -> "围绕「$title」，用「$principle」处理「$scenario」，展示自己的推理过程或实际产出。"
        }
    }

    private fun declaredVersion(text: String): String? {
        val lines = text.removePrefix("\uFEFF").lineSequence().toList()
        if (lines.firstOrNull()?.trim() != "---") return null
        return lines.drop(1).takeWhile { it.trim() != "---" }
            .firstOrNull { it.trimStart().startsWith("version:") }
            ?.substringAfter(':')?.trim()?.trim('"', '\'')?.takeIf { it.isNotBlank() }
    }

    private fun contentVersion(text: String): String = "local-" + MessageDigest.getInstance("SHA-256")
        .digest(text.toByteArray(Charsets.UTF_8)).take(6)
        .joinToString("") { (it.toInt() and 0xff).toString(16).padStart(2, '0') }

    /** 内置课程的稳定标识与默认名称，只用于提纲缺失时展示。 */
    private data class BuiltInCourse(val id: String, val kind: CoachKind, val title: String, val place: String)

    /** 从单元原始行抽出的目标、情境与产出，不引入新的书籍知识。 */
    private data class UnitTarget(val principle: String, val scenario: String, val practice: String,
        val requiresRealAction: Boolean, val title: String)
}
