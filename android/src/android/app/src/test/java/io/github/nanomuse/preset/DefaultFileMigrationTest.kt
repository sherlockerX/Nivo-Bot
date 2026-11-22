package io.github.nanomuse.preset

import java.io.File
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** 文件替换只接受读取时的原文，临时文件与用户数据互不覆盖。 */
class DefaultFileMigrationTest {
    @get:Rule
    val temporaryFolder = TemporaryFolder()

    @Test
    fun should_replaceDefaultAndCleanTemporary_when_sourceUnchanged() {
        val target = temporaryFolder.newFile("GLOBAL.md").apply { writeText("old") }
        assertTrue(DefaultFileMigration.replaceIfUnchanged(target, "old", "new"))
        assertEquals("new", target.readText())
        assertEquals(listOf("GLOBAL.md"), temporaryFolder.root.listFiles()!!.map { it.name })
    }

    @Test
    fun should_preserveEditedMemory_when_sourceChangedAfterReading() {
        val target = temporaryFolder.newFile("GLOBAL.md").apply { writeText("user memory") }
        assertFalse(DefaultFileMigration.replaceIfUnchanged(target, "old", "new"))
        assertEquals("user memory", target.readText())
    }

    @Test
    fun should_preserveExistingTemporary_when_previousRunLeftOne() {
        val target = temporaryFolder.newFile("SOUL.md").apply { writeText("old") }
        val leftover = temporaryFolder.newFile("SOUL.md.brand.tmp").apply { writeText("preserve") }
        assertTrue(DefaultFileMigration.replaceIfUnchanged(target, "old", "new"))
        assertEquals("preserve", leftover.readText())
        assertEquals("new", target.readText())
        assertEquals(2, temporaryFolder.root.listFiles()!!.size)
    }

    @Test
    fun should_notRecreateFile_when_sourceWasDeleted() {
        val target = File(temporaryFolder.root, "GLOBAL.md")
        assertFalse(DefaultFileMigration.replaceIfUnchanged(target, "old", "new"))
        assertFalse(target.exists())
    }

    @Test
    fun should_applyOnlyOneReplacement_when_migrationsShareTheSameSnapshot() {
        val target = temporaryFolder.newFile("GLOBAL.md").apply { writeText("old") }
        val workers = Executors.newFixedThreadPool(2)
        try {
            val attempts = listOf("first", "second").map { replacement ->
                workers.submit(Callable {
                    DefaultFileMigration.replaceIfUnchanged(target, "old", replacement)
                })
            }
            assertEquals(1, attempts.count { it.get(5, TimeUnit.SECONDS) })
            assertTrue(target.readText() in listOf("first", "second"))
            assertEquals(1, temporaryFolder.root.listFiles()!!.size)
        } finally {
            workers.shutdownNow()
        }
    }
}
