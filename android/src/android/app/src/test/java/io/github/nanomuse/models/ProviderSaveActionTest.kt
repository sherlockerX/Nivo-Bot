package io.github.nanomuse.models

import com.openminis.app.R
import io.github.nanomuse.ui.models.ProviderSaveAction
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** 通过受控调度验证表单保存状态及重复点击、失败重试和取消的真实行为。 */
@OptIn(ExperimentalCoroutinesApi::class)
class ProviderSaveActionTest {
    @Test
    fun `duplicate clicks commit only once and return after the write`() = runTest {
        val action = ProviderSaveAction(this, StandardTestDispatcher(testScheduler))
        val events = mutableListOf<String>()
        action.submit({ events.add("write") }, { events.add("return") })
        action.submit({ events.add("duplicate") }, { events.add("duplicate return") })
        assertTrue(action.isSaving)
        assertTrue(events.isEmpty())
        advanceUntilIdle()
        assertEquals(listOf("write", "return"), events)
        assertFalse(action.isSaving)
        assertTrue(action.hasSaved)
        assertNull(action.errorResource)
        action.submit({ events.add("late duplicate") }, { events.add("second return") })
        advanceUntilIdle()
        assertEquals(listOf("write", "return"), events)
    }

    @Test
    fun `storage failure keeps the page open and permits retry`() = runTest {
        val action = ProviderSaveAction(this, StandardTestDispatcher(testScheduler))
        var returns = 0
        action.submit({ error("private failure detail") }, { returns++ })
        advanceUntilIdle()
        assertEquals(0, returns)
        assertFalse(action.isSaving)
        assertFalse(action.hasSaved)
        assertEquals(R.string.nm_provider_save_failed, action.errorResource)
        action.submit({}, { returns++ })
        advanceUntilIdle()
        assertEquals(1, returns)
        assertNull(action.errorResource)
    }

    @Test
    fun `duplicate model failure is actionable and never exits`() = runTest {
        val action = ProviderSaveAction(this, StandardTestDispatcher(testScheduler))
        action.submit({ throw IllegalArgumentException("duplicate_model_id") }, { error("must stay") })
        advanceUntilIdle()
        assertEquals(R.string.nm_model_id_conflict, action.errorResource)
        action.dismissError()
        assertNull(action.errorResource)
    }

    @Test
    fun `cancelled save clears busy state without reporting a storage failure`() = runTest {
        val action = ProviderSaveAction(this, StandardTestDispatcher(testScheduler))
        action.submit({ throw CancellationException() }, { error("must stay") })
        advanceUntilIdle()
        assertFalse(action.isSaving)
        assertFalse(action.hasSaved)
        assertNull(action.errorResource)
    }

    @Test
    fun `restored committed provider exits once without allowing another save`() = runTest {
        val action = ProviderSaveAction(this, StandardTestDispatcher(testScheduler))
        var returns = 0
        action.finishRestoredSave { returns++ }
        action.finishRestoredSave { returns++ }
        action.submit({ error("must not write") }, { returns++ })
        advanceUntilIdle()
        assertEquals(1, returns)
        assertTrue(action.hasSaved)
    }

    @Test
    fun `config emission during saving does not trigger an extra return`() = runTest {
        val action = ProviderSaveAction(this, StandardTestDispatcher(testScheduler))
        var returns = 0
        action.submit({}, { returns++ })
        action.finishRestoredSave { returns++ }
        assertEquals(0, returns)
        advanceUntilIdle()
        action.finishRestoredSave { returns++ }
        assertEquals(1, returns)
    }

    @Test
    fun `stale editor tells the user to reopen instead of repeatedly retrying`() = runTest {
        val action = ProviderSaveAction(this, StandardTestDispatcher(testScheduler))
        action.submit({ error("model_changed") }, { error("must stay") })
        advanceUntilIdle()
        assertEquals(R.string.nm_model_edit_conflict, action.errorResource)
        assertFalse(action.hasSaved)
    }
}
