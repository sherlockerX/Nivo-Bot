package io.github.nanomuse.coach

import java.io.File
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** nanoMuse: 对照会迁移的服务初始化与只读查询，验证真实历史文件和证据保持原样。 */
class CoachReadSnapshotReaderTest {
    @get:Rule val folder = TemporaryFolder()
    private val course = CoachCourse("expression", "表达", "会客厅", CoachKind.EXPRESSION,
        listOf(CoachUnit("1.1", "先问再答", "确认关切", "重试",
            listOf(CoachCriterion("target", "确认关切")))), "legacy-v1", "original source")

    @Test fun should_preserveBundledHistory_when_commandServiceWouldUpgradeAndWrite() {
        val current = course.copy(version = "coach-curriculum-v3", importProtocol = "coach-curriculum-v3",
            builtInSourceId = course.id)
        compareReadWithMutatingInitialization(course, listOf(current))
    }

    @Test fun should_preserveLegacyImportedHistory_when_commandServiceWouldInvalidateMastery() {
        val imported = course.copy(id = "custom", version = "1.0+local-012345", source = "历史自定义课程")
        compareReadWithMutatingInitialization(imported, emptyList())
    }

    @Test fun should_readBackupWithoutRepairingFiles_when_primaryIsCorrupt() {
        val directory = folder.newFolder()
        val saved = savedState(course)
        val files = CoachFileStore(directory)
        files.save(saved)
        files.save(saved.copy(revision = saved.revision + 1))
        File(directory, "state.json").writeText("broken primary")
        val before = fileContents(directory)
        val reader = CoachReadSnapshotReader(directory) { error("已有备用档不能加载当前课程") }
        val snapshot = reader.read()
        assertEquals(saved, snapshot.state)
        assertEquals("saved_backup", snapshot.source)
        assertTrue(snapshot.hasSavedArchive)
        val output = JSONObject(reader.query("{\"kind\":\"overview\"}").output)
        assertEquals("saved_backup", output.getString("snapshot_source"))
        assertTrue(output.getBoolean("has_saved_archive"))
        assertEquals(before, fileContents(directory))
    }

    @Test fun should_returnCurrentCurriculumWithEmptyProgress_withoutCreatingArchive() {
        val directory = File(folder.root, "not-created")
        val current = course.copy(version = "current")
        val reader = CoachReadSnapshotReader(directory) { listOf(current) }
        val snapshot = reader.read()
        assertEquals("current_curriculum_without_saved_progress", snapshot.source)
        assertFalse(snapshot.hasSavedArchive)
        assertEquals(0L, snapshot.state.revision)
        assertEquals(current, snapshot.state.tracks.single().course)
        assertTrue(snapshot.state.tracks.single().demonstrated.isEmpty())
        assertTrue(snapshot.state.sessions.isEmpty())
        assertTrue(snapshot.state.topics.isEmpty())
        assertTrue(snapshot.state.actions.isEmpty())
        assertTrue(snapshot.state.drafts.isEmpty())
        val result = reader.query("{\"kind\":\"overview\"}")
        assertTrue(result.success)
        val output = JSONObject(result.output)
        assertEquals(snapshot.source, output.getString("snapshot_source"))
        assertFalse(output.getBoolean("has_saved_archive"))
        assertEquals("current_account", output.getString("scope"))
        assertFalse(directory.exists())
    }

    @Test fun should_failWithoutInventingEmptyProgress_when_bothArchivesAreCorrupt() {
        val directory = folder.newFolder()
        File(directory, "state.json").writeText("broken primary")
        File(directory, "state.backup.json").writeText("broken backup")
        val before = fileContents(directory)
        var courseLoads = 0
        val reader = CoachReadSnapshotReader(directory) { courseLoads++; listOf(course) }
        assertThrows(IllegalStateException::class.java) { reader.read() }
        assertThrows(IllegalStateException::class.java) { reader.query("{\"kind\":\"overview\"}") }
        assertEquals(0, courseLoads)
        assertEquals(before, fileContents(directory))
    }

    @Test fun should_usePrimaryAsSaved_withoutLoadingCurrentCoursesOrTouchingBrokenBackup() {
        val directory = folder.newFolder()
        val saved = savedState(course)
        CoachFileStore(directory).save(saved)
        File(directory, "state.backup.json").writeText("broken backup")
        val before = fileContents(directory)
        val snapshot = CoachReadSnapshotReader(directory) { error("已有主档不能加载当前课程") }.read()
        assertEquals(saved, snapshot.state)
        assertEquals("saved_primary", snapshot.source)
        assertTrue(snapshot.hasSavedArchive)
        assertEquals(before, fileContents(directory))
    }

    private fun compareReadWithMutatingInitialization(original: CoachCourse, currentCourses: List<CoachCourse>) {
        val saved = savedState(original)
        val readDirectory = folder.newFolder()
        val serviceDirectory = folder.newFolder()
        CoachFileStore(readDirectory).save(saved)
        CoachFileStore(serviceDirectory).save(saved)
        val before = fileContents(readDirectory)
        val reader = CoachReadSnapshotReader(readDirectory) { currentCourses }
        val snapshot = reader.read()
        val result = reader.query("{\"kind\":\"courses\",\"targetId\":\"${original.id}\"}")
        assertTrue(result.success)
        val output = JSONObject(result.output)
        assertEquals(saved, snapshot.state)
        assertEquals(saved.revision, output.getLong("revision"))
        assertEquals("1.1", output.getJSONObject("data").getJSONArray("demonstrated").getString(0))
        assertEquals("saved_primary", output.getString("snapshot_source"))
        assertTrue(output.getBoolean("has_saved_archive"))
        assertEquals(before, fileContents(readDirectory))

        // nanoMuse: 相同存档经过旧服务初始化确实写入升级，防止测试只验证一个无副作用样本。
        val migrated = CoachCommandService(CoachFileStore(serviceDirectory), currentCourses).state.value
        assertEquals(saved.revision + 1, migrated.revision)
        assertTrue(migrated.tracks.single().demonstrated.isEmpty())
        assertEquals("paused", migrated.sessions.single().status)
        assertTrue(migrated.sessions.single().requiresCourseReview)
        assertEquals(migrated, CoachFileStore(serviceDirectory).load())
        assertNotEquals(before, fileContents(serviceDirectory))
    }

    private fun savedState(original: CoachCourse): CoachState = CoachState(revision = 8,
        tracks = listOf(CoachTrack(original, demonstrated = setOf("1.1"))),
        sessions = listOf(CoachSession("old-session", original, "1.1", status = "active",
            turns = listOf(CoachTurn("original-answer", "user", "保存的真实回答", "first", createdAt = 123L)))))

    private fun fileContents(directory: File): Map<String, List<Byte>> =
        directory.listFiles().orEmpty().associate { it.name to it.readBytes().toList() }
}
