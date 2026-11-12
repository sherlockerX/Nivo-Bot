package io.github.nanomuse.coach

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** 全删选择落盘后可重启重试，只有会话已经消失才允许继续清除档案。 */
class CoachPurgeJournalTest {
    @get:Rule val folder = TemporaryFolder()

    @Test fun should_keepConfirmedDeleteAcrossRestart_andRemoveOnlyAfterSuccess() {
        val directory = folder.newFolder()
        val entry = CoachPurgeEntry("owner-a", "chat-a")
        CoachPurgeJournal(directory).put(entry)
        val restarted = CoachPurgeJournal(directory)
        assertEquals(listOf(entry), restarted.entries())
        restarted.put(entry)
        assertEquals(1, restarted.entries().size)
        restarted.remove(entry.chatId)
        assertTrue(CoachPurgeJournal(directory).entries().isEmpty())
    }

    @Test fun should_recoverOnlyDeletedConversation_forCurrentAccount() {
        val entry = CoachPurgeEntry("owner-a", "chat-a")
        assertTrue(CoachPurgeJournal.shouldPurge(entry, "owner-a", false))
        assertFalse(CoachPurgeJournal.shouldPurge(entry, "owner-a", true))
        assertFalse(CoachPurgeJournal.shouldPurge(entry, "owner-b", false))
    }

    @Test(expected = Exception::class)
    fun should_reportCorruptPendingDelete_insteadOfDiscardingIt() {
        val directory = folder.newFolder()
        File(directory, "broken.json").writeText("broken")
        CoachPurgeJournal(directory).entries()
    }

    @Test fun should_useSafeNames_when_chatIdentifierContainsPathCharacters() {
        val directory = folder.newFolder()
        val entry = CoachPurgeEntry("owner-a", "../../chat:one")
        CoachPurgeJournal(directory).put(entry)
        assertEquals(listOf(entry), CoachPurgeJournal(directory).entries())
        assertTrue(directory.listFiles()!!.all { it.parentFile == directory })
    }

    @Test fun should_invalidateOnlyExistingChangedSource_when_messagesAreAppendedOrRewritten() {
        val original = "[{\"type\":\"text\",\"value\":\"原回答\"}]"
        val changed = "[{\"type\":\"text\",\"value\":\"修改后\"}]"
        assertFalse(CoachSourceChange.shouldInvalidate(null, original))
        assertFalse(CoachSourceChange.shouldInvalidate(original, original))
        assertTrue(CoachSourceChange.shouldInvalidate(original, changed))
        assertTrue(CoachSourceChange.shouldInvalidate(original, null))
    }
}
