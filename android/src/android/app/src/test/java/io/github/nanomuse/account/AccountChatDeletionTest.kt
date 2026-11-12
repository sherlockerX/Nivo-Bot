package io.github.nanomuse.account

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

/** 用删除失败与取消验证归属保留，以及原迁移的幂等重试。 */
class AccountChatDeletionTest {
    @Test fun should_keepRemainingOwnersAndRetry_when_secondChatDeletionFails() = runBlocking {
        val gate = AccountMutationGate()
        val owners = linkedSetOf("first", "second", "third")
        val chats = owners.toMutableSet()
        val attempted = mutableListOf<String>()
        var shouldFail = true
        val deleteChat: suspend (String) -> Unit = { sessionId ->
            attempted += sessionId
            if (sessionId == "second" && shouldFail) error("消息删除失败")
            chats.remove(sessionId)
        }
        val failed = runCatching {
            gate.transition {
                deleteOwnedChats(owners.toList(), deleteChat) { owners.remove(it) }
            }
        }
        assertTrue(failed.isFailure)
        assertEquals(setOf("second", "third"), owners)
        assertEquals(owners, chats)
        assertEquals(listOf("first", "second"), attempted)
        assertTrue(runCatching { gate.requireAvailable() }.isFailure)

        shouldFail = false
        gate.transition {
            deleteOwnedChats(owners.toList(), deleteChat) { owners.remove(it) }
        }
        gate.requireAvailable()
        assertTrue(owners.isEmpty())
        assertTrue(chats.isEmpty())
        assertEquals(1, attempted.count { it == "first" })
    }

    @Test fun should_keepOwnerUntilFilesAreRemoved_when_databaseRowIsAlreadyDeleted() = runBlocking {
        val owners = linkedSetOf("chat")
        val chats = owners.toMutableSet()
        val files = owners.toMutableSet()
        var shouldFail = true
        val deleteChat: suspend (String) -> Unit = { sessionId ->
            chats.remove(sessionId)
            if (shouldFail) error("附件删除失败")
            files.remove(sessionId)
        }
        assertTrue(runCatching {
            deleteOwnedChats(owners.toList(), deleteChat) { owners.remove(it) }
        }.isFailure)
        assertTrue(chats.isEmpty())
        assertEquals(setOf("chat"), owners)
        assertEquals(setOf("chat"), files)

        shouldFail = false
        deleteOwnedChats(owners.toList(), deleteChat) { owners.remove(it) }
        assertTrue(files.isEmpty())
        assertTrue(owners.isEmpty())
    }

    @Test fun should_preserveOwnerAndStop_when_deletionIsCancelled() = runBlocking {
        val owners = linkedSetOf("first", "second")
        val attempted = mutableListOf<String>()
        val cancellation = CancellationException("删除已取消")
        val result = runCatching {
            deleteOwnedChats(owners.toList(), { sessionId ->
                attempted += sessionId
                throw cancellation
            }) { owners.remove(it) }
        }
        assertSame(cancellation, result.exceptionOrNull())
        assertEquals(setOf("first", "second"), owners)
        assertEquals(listOf("first"), attempted)
    }
}
