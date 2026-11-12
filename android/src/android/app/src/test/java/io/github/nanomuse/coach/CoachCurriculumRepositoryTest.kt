package io.github.nanomuse.coach

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** 验证原课程的单元、训练目标与材料边界在导入后保持完整。 */
class CoachCurriculumRepositoryTest {
    @Test
    fun should_preserveExactUnitTargetAndSource_when_parsingChineseCurriculum() {
        val originalLine = "- 1.3 下一步行动（C；B02 B05）：模糊的任务引发回避；\"写论文\"三周没动；把最拖的3件事改写成10分钟能做的下一步，并完成其中一件。"
        val text = "---\r\nversion: 2.0.0\r\n---\r\n# 习惯与执行力\r\n\r\n$originalLine\r\n"

        val course = CoachCurriculumRepository.parse("habits", CoachKind.EXECUTION, text)
        val unit = course.units.single()

        assertEquals("习惯与执行力", course.title)
        assertTrue(course.version.startsWith("2.0.0+"))
        assertEquals(text, course.source)
        assertEquals("1.3", unit.id)
        assertEquals("下一步行动", unit.title)
        assertEquals("模糊的任务引发回避；\"写论文\"三周没动；把最拖的3件事改写成10分钟能做的下一步，并完成其中一件。", unit.focus)
        assertEquals(originalLine, unit.source)
    }

    @Test
    fun should_changeSnapshotVersion_when_sourceChangesWithoutDeclaredVersionBump() {
        val original = "---\nversion: 2.0.0\n---\n# 原课程\n- 1.1 单元（A；B01）：解释；情境；练习。\n"
        val edited = original.replace("练习。", "修改后的练习。")

        assertNotEquals(
            CoachCurriculumRepository.parse("principles", CoachKind.JUDGMENT, original).version,
            CoachCurriculumRepository.parse("principles", CoachKind.JUDGMENT, edited).version,
        )
    }

    @Test
    fun should_keepFileOrder_when_unitNumbersAreNotSorted() {
        val text = """
            # 我的课程
            - 2.1 先出现的单元（A；B01）：观察；一个情境；提交观察。
            - 1.10 后出现的单元（A；B01）：比较；另一个情境；提交比较。
            - 1.2 最后出现的单元（A；B01）：修订；第三个情境；提交修订。
        """.trimIndent()

        val course = CoachCurriculumRepository.parse("custom-order", CoachKind.CUSTOM, text)

        assertEquals(listOf("2.1", "1.10", "1.2"), course.units.map { it.id })
        assertEquals(listOf("先出现的单元", "后出现的单元", "最后出现的单元"), course.units.map { it.title })
    }

    @Test
    fun should_ignoreExamplesAndOtherLists_when_numberedLinesAppearInsideCodeFences() {
        val text = """
            # 课程
            - B01《一本书》：课程引用。
            - A 能力框架：不是单元。
            ```markdown
            - 9.1 示例单元（A）：不能导入。
            ```
            ~~~
            - 9.2 另一个示例（A）：不能导入。
            ~~~
            > - 9.3 引用示例：不能导入。
            - 1.1 真实单元（A；B01）：解释；情境；练习。
        """.trimIndent()

        val course = CoachCurriculumRepository.parse("custom-fences", CoachKind.CUSTOM, text)

        assertEquals(listOf("1.1"), course.units.map { it.id })
    }

    @Test
    fun should_parseAsciiMetadata_when_customCourseUsesEnglishPunctuation() {
        val text = """
            ---
            version: "1.4"
            ---
            # Writing practice
            - 1.1 CARS introduction (C; B01 B08): Establish a field; identify a gap; write five sentences.
        """.trimIndent()

        val unit = CoachCurriculumRepository.parse("custom-writing", CoachKind.ENGLISH, text).units.single()

        assertEquals("CARS introduction", unit.title)
        assertEquals("Establish a field; identify a gap; write five sentences.", unit.focus)
    }

    @Test
    fun should_keepEmptyCurriculumExplicit_when_noUnitLinesExist() {
        val text = "# 尚未编写的课程\n\n## 书单\n- B01：仅有书目，尚无课程。\n"

        val course = CoachCurriculumRepository.parse("custom-empty", CoachKind.CUSTOM, text)

        assertEquals("尚未编写的课程", course.title)
        assertTrue(course.units.isEmpty())
        assertEquals(text, course.source)
        assertFalse(course.version.isBlank())
    }

    @Test
    fun should_keepTitleAsTheOnlyAvailableFocus_when_unitHasNoDescription() {
        val course = CoachCurriculumRepository.parse(
            "custom-outline", CoachKind.CUSTOM, "# 只列标题的提纲\n- 1.1 我想练的问题\n",
        )
        val unit = course.units.single()

        assertEquals("我想练的问题", unit.title)
        assertEquals("我想练的问题", unit.focus)
        assertTrue(unit.method.contains("未提供"))
        assertTrue(unit.criteria.all { it.description.contains("我想练的问题") })
    }

    @Test
    fun should_useUnitSpecificCriteria_when_sameKindContainsDifferentTargets() {
        val text = """
            # 英语表达
            - 1.5 三句请求邮件（D；B05）：背景、请求、期限；向论文作者要代码；提交三句请求邮件。
            - 2.3 主张强度（B D；B01 B04）：动词和情态词决定主张有多强；把prove改成证据撑得住的说法；给讨论部分的每句标出强度。
        """.trimIndent()

        val units = CoachCurriculumRepository.parse("english", CoachKind.ENGLISH, text).units
        val emailCriteria = units.first().criteria.joinToString { it.description }
        val claimCriteria = units.last().criteria.joinToString { it.description }

        assertTrue(emailCriteria.contains("背景、请求、期限"))
        assertTrue(emailCriteria.contains("提交三句请求邮件"))
        assertTrue(claimCriteria.contains("prove"))
        assertTrue(claimCriteria.contains("给讨论部分的每句标出强度"))
        assertNotEquals(emailCriteria, claimCriteria)
    }

    @Test
    fun should_requireReportedAction_when_executionUnitHasARealPracticeTask() {
        val text = """
            # 习惯与执行力
            - 1.1 最小行为（A C；B04 B01）：原理：先降低开始门槛；情景：每天读论文却开不了头；实践：连续7天做最小动作并记录；现实行动：是
        """.trimIndent()

        val unit = CoachCurriculumRepository.parse("habits", CoachKind.EXECUTION, text).units.single()
        val actionCriterion = unit.criteria.single { it.requiresRealAction }

        assertTrue(actionCriterion.description.contains("连续7天做最小动作并记录"))
        assertTrue(actionCriterion.description.contains("实际"))
        assertTrue(actionCriterion.description.contains("报告"))
        assertTrue(unit.method.contains("计划不能代替"))
    }

    @Test
    fun should_varyTeachingByCourseKind_when_unitFocusIsTheSame() {
        val text = "# 示例课程\n- 1.1 一个目标（A；B01）：理解这个目标；一个具体情境；提交练习。\n"
        val methods = CoachKind.entries.associateWith { kind ->
            CoachCurriculumRepository.parse("test", kind, text).units.single().method
        }

        assertEquals(CoachKind.entries.size, methods.values.toSet().size)
        assertTrue(methods.getValue(CoachKind.JUDGMENT).contains("事实"))
        assertTrue(methods.getValue(CoachKind.PERSPECTIVES).contains("视角"))
        assertTrue(methods.getValue(CoachKind.ENGLISH).contains("英文"))
        assertTrue(methods.getValue(CoachKind.EXPRESSION).contains("角色"))
        assertTrue(methods.getValue(CoachKind.LEADERSHIP).contains("合作"))
        assertTrue(methods.getValue(CoachKind.EXECUTION).contains("实际"))
    }

    @Test
    fun should_discloseSourceLimits_when_originalOutlineCitesBooks() {
        val text = "# 原课程\n\n## 书单\n- B01《示例书》\n\n- 1.1 原提纲单元（A；B01）：原提纲主张；情境；提交记录。\n"

        val unit = CoachCurriculumRepository.parse("principles", CoachKind.JUDGMENT, text).units.single()

        assertTrue(unit.method.contains("原课程引用"))
        assertTrue(unit.method.contains("尚未重新核验"))
        assertTrue(unit.method.contains("不编造"))
        assertEquals(text, CoachCurriculumRepository.parse("principles", CoachKind.JUDGMENT, text).source)
    }

    @Test
    fun should_importAllSixExistingCurricula_when_parsingBundledSkills() {
        val expected = listOf(
            BuiltInExpectation("principles", CoachKind.JUDGMENT, 20, "决策日志", "把原则带进小组"),
            BuiltInExpectation("lenses", CoachKind.PERSPECTIVES, 19, "换镜头", "多视角长文"),
            BuiltInExpectation("english", CoachKind.ENGLISH, 23, "四条线与语音日志", "主动联络"),
            BuiltInExpectation("expression", CoachKind.EXPRESSION, 20, "先问再答", "个人表达手册"),
            BuiltInExpectation("leadership", CoachKind.LEADERSHIP, 21, "看见自己的时间", "小团队实战"),
            BuiltInExpectation("habits", CoachKind.EXECUTION, 18, "最小行为", "我的执行系统"),
        )

        expected.forEach { fixture ->
            val text = bundledCourse(fixture.id).readText()
            val course = CoachCurriculumRepository.parse(fixture.id, fixture.kind, text)

            assertEquals(fixture.id, fixture.unitCount, course.units.size)
            assertEquals(fixture.firstTitle, course.units.first().title)
            assertEquals(fixture.lastTitle, course.units.last().title)
            assertEquals(text, course.source)
            assertTrue(course.units.all { it.focus.isNotBlank() && it.criteria.isNotEmpty() })
            assertEquals(course.units.size, course.units.map { it.id }.toSet().size)
        }
    }

    private fun bundledCourse(id: String): File = listOf(
        "src/main/assets/preset/skills/growth-$id/SKILL.md",
        "app/src/main/assets/preset/skills/growth-$id/SKILL.md",
        "android/src/android/app/src/main/assets/preset/skills/growth-$id/SKILL.md",
    ).map(::File).first { it.isFile }

    @Test
    fun should_requireRealReportsByExplicitUnit_when_importingAllBundledCourses() {
        val expected = mapOf(
            "principles" to "1.1 1.2 2.1 2.2 2.3 2.4 3.1 3.3 3.4 4.1 4.2 4.3 4.4 5.2 5.3 5.4",
            "lenses" to "1.1 1.2 2.1 3.1 3.2 3.4 4.1 4.2 4.3 4.4 5.2 5.3",
            "english" to "1.1 1.2 1.3 1.4 1.5 2.1 2.2 2.4 2.5 3.2 3.3 3.4 3.5 4.1 4.2 5.2 5.3 5.4",
            "expression" to "1.1 1.2 1.3 1.4 2.1 2.2 2.3 2.4 3.1 3.2 3.3 3.4 4.1 4.2 4.3 4.4 5.1 5.2 5.3 5.4",
            "leadership" to "1.1 1.2 1.3 1.4 2.1 2.2 2.3 2.4 3.1 3.2 3.3 3.4 4.1 4.2 4.3 4.4 5.1 5.2 5.3 5.5",
            "habits" to "1.1 1.2 1.3 1.4 2.1 2.3 2.4 3.1 3.2 3.3 3.4 4.1 4.2 4.3 5.1 5.2 5.3",
        )
        expected.forEach { (id, realIds) ->
            val kind = when (id) {
                "principles" -> CoachKind.JUDGMENT; "lenses" -> CoachKind.PERSPECTIVES
                "english" -> CoachKind.ENGLISH; "expression" -> CoachKind.EXPRESSION
                "leadership" -> CoachKind.LEADERSHIP; else -> CoachKind.EXECUTION
            }
            val course = CoachCurriculumRepository.parse(id, kind, bundledCourse(id).readText())
            assertEquals(id, course.builtInSourceId)
            assertEquals("coach-curriculum-v3", course.importProtocol)
            assertEquals(id, realIds.split(' ').toSet(), course.units.filter {
                it.criteria.any(CoachCriterion::requiresRealAction)
            }.map { it.id }.toSet())
        }
    }

    @Test
    fun should_notTreatExtraTheoryAsScenario_when_importingPrinciplesTwoOne() {
        val course = CoachCurriculumRepository.parse("principles", CoachKind.JUDGMENT, bundledCourse("principles").readText())
        val criteria = course.units.single { it.id == "2.1" }.criteria
        assertTrue(criteria.single { it.id == "application" }.description.contains("在「二手卖家先报高价再让利」"))
        assertTrue(criteria.single { it.id == "understanding" }.description.contains("最常见的是锚定"))
        assertFalse(criteria.single { it.id == "practice" }.description.contains("二手卖家"))
        assertTrue(course.version.contains("coach-curriculum-v3"))
    }

    @Test
    fun should_notDuplicatePracticeAsScenario_when_unitHasNoScenario() {
        val course = CoachCurriculumRepository.parse("habits", CoachKind.EXECUTION, bundledCourse("habits").readText())
        val criterion = course.units.single { it.id == "5.3" }.criteria.single { it.id == "application" }
        assertFalse(criterion.description.contains("针对「写一页系统说明书"))
        assertTrue(criterion.description.contains("未提供独立情景"))
    }

    @Test
    fun should_notReuseBundledUnitMetadata_when_installedUnitTextWasEdited() {
        val text = bundledCourse("english").readText().replace(
            "给一位真实的作者或管理员发出一封三句请求邮件。", "提交一封模拟邮件。")
        val course = CoachCurriculumRepository.parse("english", CoachKind.ENGLISH, text)
        val criterion = course.units.single { it.id == "1.5" }.criteria.single { it.id == "practice" }
        assertFalse(criterion.requiresRealAction)
        assertFalse(criterion.description.contains("真实的作者"))
        assertEquals("", course.builtInSourceId)
        assertTrue(course.needsCriteriaReview)
        assertTrue(course.units.single { it.id == "1.5" }.needsCriteriaReview)
    }

    @Test
    fun should_useExplicitRealityField_forCustomCoursesInsteadOfKindOrActionWords() {
        val text = """
            # 自定练习
            - 1.1 模拟邮件：原理：写清请求；情景：向作者要资料；实践：写一封不发送的邮件；现实行动：否
            - 1.2 现实邮件：原理：检验实际结果；情景：联系作者；实践：发出邮件并报告结果；现实行动：是
        """.trimIndent()
        CoachKind.entries.forEach { kind ->
            val course = CoachCurriculumRepository.parse("custom", kind, text)
            assertFalse(course.units[0].criteria.single { it.id == "practice" }.requiresRealAction)
            assertTrue(course.units[1].criteria.single { it.id == "practice" }.requiresRealAction)
            assertEquals("", course.builtInSourceId)
            assertFalse(course.needsCriteriaReview)
        }
    }

    @Test
    fun should_requireReview_when_explicitImportedFieldsAreMissingOrAmbiguous() {
        listOf(
            "原理：目标；实践：去发邮件；现实行动：否",
            "原理：目标；情景：场景；实践：去发邮件",
            "原理：目标；情景：场景；实践：去发邮件；现实行动：可能",
            "原理：目标；情景：场景；实践：去发邮件；现实行动：是；现实行动：否",
            "原理：；情景：场景；实践：去发邮件；现实行动：是",
            "旧格式原理；旧格式情景；给真实作者发邮件",
        ).forEach { description ->
            val course = CoachCurriculumRepository.parse("custom", CoachKind.CUSTOM, "# 我的课\n- 1.1 单元：$description")
            assertTrue(description, course.needsCriteriaReview)
            assertTrue(course.units.single().needsCriteriaReview)
        }
    }

    @Test
    fun should_identifyOnlyCompleteOrderedAndFingerprintMatchedBuiltIns() {
        var total = 0
        listOf("principles", "lenses", "english", "expression", "leadership", "habits").forEach { id ->
            val text = bundledCourse(id).readText()
            val lines = text.lines().filter { it.matches(Regex("^\\s*-\\s+\\d+\\.\\d+.*")) }
            val course = CoachCurriculumRepository.parse(id, CoachKind.CUSTOM, text)
            total += lines.size
            assertEquals(id, course.builtInSourceId)
            assertFalse(course.needsCriteriaReview)
            assertTrue(course.units.none { it.needsCriteriaReview })
            lines.forEach { source ->
                val unitId = Regex("^\\s*-\\s+(\\d+\\.\\d+)").find(source)!!.groupValues[1]
                assertTrue("$id:$unitId", CoachBuiltInUnits.target(id, unitId, source) != null)
                assertEquals(null, CoachBuiltInUnits.target(id, unitId, source + "已修改"))
            }
            assertEquals("", CoachCurriculumRepository.parse(id, CoachKind.CUSTOM,
                text.replace(lines.last(), "")).builtInSourceId)
            assertEquals("", CoachCurriculumRepository.parse(id, CoachKind.CUSTOM,
                "# 调序\n" + lines.reversed().joinToString("\n")).builtInSourceId)
        }
        assertEquals(121, total)
    }

    /** 六份真实提纲的首尾与单元总数，防止只导入首课或截短课程。 */
    private data class BuiltInExpectation(
        val id: String,
        val kind: CoachKind,
        val unitCount: Int,
        val firstTitle: String,
        val lastTitle: String,
    )
}
