package io.github.nanomuse.coach

import org.junit.Assert.*
import org.junit.Test
import org.junit.Rule
import org.junit.rules.TemporaryFolder
import java.io.File

/** 验证迁移期间既不保留旧服务，也不创建读取半迁移目录的新服务。 */
class CoachSpaceGateTest {
    @get:Rule val folder = TemporaryFolder()
    @Test fun should_rejectCreationUntilFinished_when_spaceChanges() {
        val invalidated = mutableListOf<String>()
        val gate = CoachSpaceGate<String> { invalidated += it }
        assertEquals("a", gate.get { "a" })
        gate.begin()
        gate.reset()
        var didReadDirectory = false
        assertTrue(runCatching { gate.get { didReadDirectory = true; "b" } }.isFailure)
        assertFalse(didReadDirectory)
        assertEquals(listOf("a"), invalidated)
        gate.finish()
        assertEquals("b", gate.get { "b" })
    }

    @Test fun should_rejectStaleServiceWrite_when_accountDirectoryIsReplaced() {
        val active = folder.newFolder("active")
        val saved = File(folder.root, "saved-a")
        val course = CoachCourse("course", "课程", "练习", CoachKind.EXPRESSION,
            listOf(CoachUnit("unit", "单元", "来源", "练习",
                listOf(CoachCriterion("understanding", "解释")))), "v1")
        val gate = CoachSpaceGate<CoachCommandService> { it.invalidate() }
        val old = gate.get { CoachCommandService(CoachFileStore(active), listOf(course)) }
        assertTrue(old.execute(CoachCommand("pause_course", "old", 0, course.id)).success)
        gate.begin()
        assertTrue(active.renameTo(saved))
        assertTrue(active.mkdirs())
        gate.reset()
        assertTrue(runCatching { gate.get { error("迁移中不能读取目录") } }.isFailure)
        gate.finish()
        val current = gate.get { CoachCommandService(CoachFileStore(active), listOf(course)) }
        assertFalse(old.execute(CoachCommand("resume_course", "stale", 1, course.id)).success)
        assertFalse(current.state.value.tracks.single().paused)
        assertTrue(CoachCommandService(CoachFileStore(saved), listOf(course)).state.value.tracks.single().paused)
    }

    @Test fun should_invalidateCachedDirectory_when_contextUsesAnotherFilesDir() {
        val invalidated = mutableListOf<String>()
        val gate = CoachSpaceGate<String> { invalidated += it }
        assertEquals("first", gate.get("/isolated/first") { "first" })
        assertEquals("second", gate.get("/isolated/second") { "second" })
        assertEquals(listOf("first"), invalidated)
        gate.begin()
        assertTrue(runCatching { gate.get("/isolated/third") { "third" } }.isFailure)
        assertEquals(listOf("first", "second"), invalidated)
        gate.finish()
        assertEquals("third", gate.get("/isolated/third") { "third" })
    }
}
