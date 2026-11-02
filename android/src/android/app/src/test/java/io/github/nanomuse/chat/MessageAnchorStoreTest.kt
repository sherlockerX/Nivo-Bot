package io.github.nanomuse.chat

import android.content.SharedPreferences
import com.openminis.app.ui.chat.ChatMessage
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test
import org.mockito.Mockito.*

/** 验证真实存储适配器的重开、合并身份取消和保存失败语义。 */
class MessageAnchorStoreTest {
    @Test fun `bookmarks reopen without copying text and merged aliases can be removed`() = runBlocking {
        val storage = PreferencesMemory()
        val first = MessageAnchorStore { storage.preferences }
        val message = ChatMessage("ui", "assistant", "不应复制的完整正文", sourceDbIds = listOf("db-one", "db-two"))
        first.toggle("chat", message)
        val reopened = MessageAnchorStore { storage.preferences }
        withTimeout(2000) { reopened.ready.first { it } }
        assertEquals(setOf("db-one"), reopened.state.value["chat"])
        assertFalse(storage.values.toString().contains(message.content))
        reopened.toggle("chat", message.copy(id = "new-ui", sourceDbIds = listOf("db-two", "db-one")))
        assertTrue(reopened.state.value["chat"].orEmpty().isEmpty())
    }

    @Test fun `a failed disk commit does not pretend the bookmark was saved`() = runBlocking {
        val storage = PreferencesMemory()
        val store = MessageAnchorStore { storage.preferences }
        val message = ChatMessage("u", "user", "提问")
        storage.succeeds = false
        try { store.toggle("chat", message); fail("save must fail") } catch (_: IllegalStateException) { }
        assertTrue(store.state.value["chat"].orEmpty().isEmpty())
        assertTrue(storage.values.isEmpty())
    }

    private class PreferencesMemory {
        val values = linkedMapOf<String, Set<String>>()
        var succeeds = true
        val preferences = mock(SharedPreferences::class.java)
        private val editor = mock(SharedPreferences.Editor::class.java)
        private var key: String? = null
        private var pending: Set<String> = emptySet()
        init {
            `when`(preferences.all).thenAnswer { values.toMap() }
            `when`(preferences.edit()).thenReturn(editor)
            `when`(editor.putStringSet(anyString(), anySet())).thenAnswer { call ->
                key = call.getArgument(0); pending = call.getArgument<Set<String>>(1).toSet(); editor
            }
            `when`(editor.commit()).thenAnswer {
                if (succeeds) values[key!!] = pending
                succeeds
            }
        }
    }
}
