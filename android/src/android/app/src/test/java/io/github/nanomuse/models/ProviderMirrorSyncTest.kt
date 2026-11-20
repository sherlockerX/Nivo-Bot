package io.github.nanomuse.models

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CancellationException

/** 用独立的数据库与镜像模拟故障和重启，验证旧镜像不能撤销已提交的配置。 */
class ProviderMirrorSyncTest {
    @Test
    fun should_keepCommittedDatabase_when_mirrorCommitReturnsFalse() = runBlocking {
        val disk = Disk()

        assertEquals(ProviderMirrorSync.Result.PENDING, disk.save("new", mirrorSucceeds = false))

        assertEquals("new", disk.database)
        assertEquals("old", disk.mirror)
        assertEquals("new", disk.loadAfterRestart())
        assertTrue(disk.isPending)
    }

    @Test
    fun should_keepEmptyDatabase_when_lastProviderWasDeletedAndMirrorFails() = runBlocking {
        val disk = Disk()
        disk.save("", mirrorSucceeds = false)

        assertTrue(ProviderMirrorSync.hasDatabaseSnapshot(0, hasMarker = true, hasSyncHash = true))
        assertEquals("", disk.loadAfterRestart())
        assertEquals("old", disk.mirror)
    }

    @Test
    fun should_notWriteMirror_when_databaseTransactionFails() {
        val disk = Disk()
        assertThrows(IllegalStateException::class.java) {
            runBlocking { disk.save("new", databaseFails = true) }
        }

        assertEquals("old", disk.database)
        assertEquals("old", disk.mirror)
        assertEquals(listOf("database"), disk.events)
    }

    @Test
    fun should_keepPendingFlag_when_mirrorWriterThrows() = runBlocking {
        val disk = Disk()
        val result = ProviderMirrorSync.persist(
            writeDatabase = { disk.database = "new"; disk.isPending = true },
            writeMirror = { error("mirror unavailable") },
            markMirrorSynced = { error("must not acknowledge") },
        )

        assertEquals(ProviderMirrorSync.Result.PENDING, result)
        assertEquals("new", disk.loadAfterRestart())
        assertTrue(disk.isPending)
    }

    @Test
    fun should_clearPendingOnlyAfterBothWrites_when_saveSucceeds() = runBlocking {
        val disk = Disk()

        assertEquals(ProviderMirrorSync.Result.SYNCED, disk.save("new"))

        assertEquals(listOf("database", "mirror", "acknowledge"), disk.events)
        assertFalse(disk.isPending)
        assertEquals("new", disk.loadAfterRestart())
    }

    @Test
    fun should_retryMirrorRepair_when_acknowledgementFails() = runBlocking {
        val disk = Disk()
        assertEquals(ProviderMirrorSync.Result.PENDING, disk.save("new", acknowledgementFails = true))
        assertTrue(disk.isPending)
        assertEquals("new", disk.mirror)
        assertEquals("new", disk.loadAfterRestart())

        val result = ProviderMirrorSync.synchronize(
            writeMirror = { disk.mirror = disk.database; true },
            markMirrorSynced = { disk.isPending = false },
        )
        assertEquals(ProviderMirrorSync.Result.SYNCED, result)
        assertFalse(disk.isPending)
    }

    @Test
    fun should_propagateCancellationWithoutLosingPendingState_when_interruptedBeforeMirror() {
        val disk = Disk()
        assertThrows(CancellationException::class.java) {
            runBlocking {
                ProviderMirrorSync.persist(
                    writeDatabase = { disk.database = "new"; disk.isPending = true },
                    writeMirror = { throw CancellationException() },
                    markMirrorSynced = { error("must not acknowledge") },
                )
            }
        }
        assertEquals("old", disk.mirror)
        assertEquals("new", disk.loadAfterRestart())
    }

    @Test
    fun should_preserveCommittedState_when_interruptedBeforeAcknowledgement() {
        val disk = Disk()
        assertThrows(CancellationException::class.java) {
            runBlocking {
                ProviderMirrorSync.persist(
                    writeDatabase = { disk.database = "new"; disk.isPending = true },
                    writeMirror = { disk.mirror = "new"; true },
                    markMirrorSynced = { throw CancellationException() },
                )
            }
        }
        assertTrue(disk.isPending)
        assertEquals("new", disk.loadAfterRestart())
    }

    @Test
    fun should_refuseOldMirror_when_pendingDatabaseCannotBeRead() {
        assertThrows(IllegalStateException::class.java) {
            ProviderMirrorSync.shouldUseDatabase(false, true, "new", "old")
        }
    }

    @Test
    fun should_keepDowngradeImport_when_syncedMirrorWasChangedByOlderVersion() {
        assertFalse(ProviderMirrorSync.shouldUseDatabase(true, false, "old", "changed"))
        assertTrue(ProviderMirrorSync.shouldUseDatabase(true, false, "same", "same"))
    }

    @Test
    fun should_recognizeInitializedEmptyDatabase_when_syncMetadataExists() {
        assertTrue(ProviderMirrorSync.hasDatabaseSnapshot(0, hasMarker = true, hasSyncHash = false))
        assertTrue(ProviderMirrorSync.hasDatabaseSnapshot(0, hasMarker = false, hasSyncHash = true))
        assertFalse(ProviderMirrorSync.hasDatabaseSnapshot(0, hasMarker = false, hasSyncHash = false))
        assertTrue(ProviderMirrorSync.hasDatabaseSnapshot(1, hasMarker = false, hasSyncHash = false))
    }

    /** 状态仅代表持久介质，重启读取不依赖写入者的内存缓存。 */
    private class Disk {
        var database = "old"
        var mirror = "old"
        var storedHash = "old"
        var isPending = false
        val events = mutableListOf<String>()

        suspend fun save(
            content: String,
            mirrorSucceeds: Boolean = true,
            databaseFails: Boolean = false,
            acknowledgementFails: Boolean = false,
        ): ProviderMirrorSync.Result = ProviderMirrorSync.persist(
            writeDatabase = {
                events.add("database")
                check(!databaseFails)
                database = content
                storedHash = content
                isPending = true
            },
            writeMirror = {
                events.add("mirror")
                assertTrue(isPending)
                if (mirrorSucceeds) mirror = content
                mirrorSucceeds
            },
            markMirrorSynced = {
                events.add("acknowledge")
                check(!acknowledgementFails)
                isPending = false
            },
        )

        fun loadAfterRestart(): String = if (
            ProviderMirrorSync.shouldUseDatabase(true, isPending, storedHash, mirror)
        ) database else mirror
    }
}
