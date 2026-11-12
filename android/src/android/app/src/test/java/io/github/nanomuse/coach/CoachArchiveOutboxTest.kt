package io.github.nanomuse.coach

import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

/** 故障恢复只影响目标聊天，消息顺序与首次课次绑定不能被重试改写。 */
class CoachArchiveOutboxTest {
    @Test fun should_keepLessonAndOriginal_when_reopenedAfterProcessExit() {
        val root = Files.createTempDirectory("coach-outbox").toFile()
        val entry = entry("message-one", 4)
        CoachArchiveOutbox(root).put(entry)
        val reopened = CoachArchiveOutbox(root)
        assertEquals(listOf(entry), reopened.entries("chat-one"))
        assertTrue(reopened.entries("chat-two").isEmpty())
        reopened.put(entry)
        assertEquals(1, reopened.entries("chat-one").size)
        reopened.remove("chat-one", "message-one")
        assertTrue(reopened.entries("chat-one").isEmpty())
    }

    @Test fun should_isolateCorruptChat_when_anotherConversationIsRead() {
        val root = Files.createTempDirectory("coach-corrupt").toFile()
        val store = CoachArchiveOutbox(root)
        store.put(entry("broken-message", 0))
        store.put(entry("good-message", 1, "chat-two"))
        val corrupt = record(root, "chat-one", "broken-message").apply { writeText("broken") }
        val healthy = store.read("chat-two")
        assertEquals(listOf("good-message"), healthy.entries.map { it.messageId })
        assertTrue(healthy.errors.isEmpty())
        assertEquals(1, store.read("chat-one").errors.size)
        assertEquals("broken", corrupt.readText())
    }

    @Test fun should_keepHealthyEntries_when_oneRecordInTheSameChatIsCorrupt() {
        val root = Files.createTempDirectory("coach-partial").toFile()
        val store = CoachArchiveOutbox(root)
        store.put(entry("broken-message", 0))
        store.put(entry("good-message", 1))
        record(root, "chat-one", "broken-message").writeText("broken")
        val snapshot = store.read("chat-one")
        assertEquals(listOf("good-message"), snapshot.entries.map { it.messageId })
        assertEquals(1, snapshot.errors.size)
    }

    @Test fun should_usePersistedOrder_when_filesHaveEqualOrReversedTimestamps() {
        val root = Files.createTempDirectory("coach-order").toFile()
        val store = CoachArchiveOutbox(root)
        store.put(entry("answer", 11).copy(role = "assistant"))
        store.put(entry("question", 10))
        record(root, "chat-one", "answer").setLastModified(1_000)
        record(root, "chat-one", "question").setLastModified(8_000)
        assertEquals(listOf("question", "answer"), store.entries("chat-one").map { it.messageId })
        record(root, "chat-one", "question").setLastModified(1_000)
        assertEquals(listOf("question", "answer"), CoachArchiveOutbox(root).entries("chat-one").map { it.messageId })
    }

    @Test fun should_preserveInitialLessonAndOrder_when_theSameMessageIsStagedAgain() {
        val root = Files.createTempDirectory("coach-repeat").toFile()
        val initial = entry("message-one", 4)
        CoachArchiveOutbox(root).put(initial)
        val repeated = initial.copy(lessonId = "lesson-two", sortOrder = 99)
        assertEquals(initial, CoachArchiveOutbox(root).put(repeated))
        assertEquals(listOf(initial), CoachArchiveOutbox(root).entries("chat-one"))
    }

    @Test fun should_rejectChangedSourceOrOwner_when_messageIdentityAlreadyExists() {
        val root = Files.createTempDirectory("coach-source").toFile()
        val store = CoachArchiveOutbox(root)
        val initial = entry("message-one", 4)
        store.put(initial)
        listOf(initial.copy(sourceHash = "changed"), initial.copy(text = "改写原话"),
            initial.copy(owner = "another-owner"), initial.copy(role = "assistant")).forEach { changed ->
            assertThrows(IllegalArgumentException::class.java) { store.put(changed) }
        }
        assertEquals(listOf(initial), store.entries("chat-one"))
    }

    @Test fun should_removeOnlyTargetChat_when_itsRecordCannotBeParsed() {
        val root = Files.createTempDirectory("coach-forget").toFile()
        val store = CoachArchiveOutbox(root)
        store.put(entry("message-one", 0))
        store.put(entry("message-two", 0, "chat-two"))
        record(root, "chat-one", "message-one").writeText("broken")
        store.forget("chat-one")
        assertTrue(store.read("chat-one").errors.isEmpty())
        assertTrue(store.entries("chat-one").isEmpty())
        assertEquals(1, store.entries("chat-two").size)
    }

    @Test fun should_shareLockAcrossInstances_when_theSameIdentityIsStagedConcurrently() {
        val root = Files.createTempDirectory("coach-lock").toFile()
        val pool = Executors.newFixedThreadPool(2)
        val start = CountDownLatch(1)
        try {
            val writes = listOf("lesson-one", "lesson-two").map { lesson ->
                pool.submit<CoachArchiveEntry> {
                    start.await()
                    CoachArchiveOutbox(root).put(entry("message-one", 4).copy(lessonId = lesson))
                }
            }
            start.countDown()
            val results = writes.map { it.get(5, TimeUnit.SECONDS) }
            assertEquals(results.first(), results.last())
            assertEquals(listOf(results.first()), CoachArchiveOutbox(root).entries("chat-one"))
        } finally {
            pool.shutdownNow()
        }
    }

    @Test fun should_reportUnavailableDirectory_when_chatPathIsAFile() {
        val root = Files.createTempDirectory("coach-path").toFile()
        val folder = record(root, "chat-one", "message-one").parentFile
        folder.writeText("not a directory")
        val snapshot = CoachArchiveOutbox(root).read("chat-one")
        assertTrue(snapshot.entries.isEmpty())
        assertEquals(1, snapshot.errors.size)
        assertEquals("not a directory", folder.readText())
    }

    @Test fun should_rejectMismatchedIdentity_when_recordWasMovedIntoAnotherChat() {
        val root = Files.createTempDirectory("coach-identity").toFile()
        val store = CoachArchiveOutbox(root)
        store.put(entry("message-one", 0))
        store.put(entry("message-two", 0, "chat-two"))
        val destination = record(root, "chat-two", "message-one")
        record(root, "chat-one", "message-one").copyTo(destination)
        val snapshot = store.read("chat-two")
        assertEquals(listOf("message-two"), snapshot.entries.map { it.messageId })
        assertEquals(1, snapshot.errors.size)
        assertTrue(destination.exists())
    }

    @Test fun should_rejectTraversal_when_sourceIdentifierIsInvalid() {
        val root = Files.createTempDirectory("coach-traversal").toFile()
        val store = CoachArchiveOutbox(root)
        assertThrows(IllegalArgumentException::class.java) { store.remove("chat-one", "../outside") }
        assertThrows(IllegalArgumentException::class.java) { store.put(entry("../outside", 0)) }
        assertTrue(root.listFiles().orEmpty().isEmpty())
    }

    private fun entry(id: String, order: Int, chatId: String = "chat-one") = CoachArchiveEntry(
        chatId, id, "lesson-one", "user", "真实原话", "digest", order, "owner-one")

    private fun record(root: File, chatId: String, messageId: String): File {
        val directory = MessageDigest.getInstance("SHA-256").digest(chatId.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
        return root.resolve(directory).resolve("$messageId.json")
    }
}
