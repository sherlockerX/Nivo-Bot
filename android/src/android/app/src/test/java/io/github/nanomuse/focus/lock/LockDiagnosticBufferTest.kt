package io.github.nanomuse.focus.lock

import org.junit.Assert.*
import org.junit.Test

/** 诊断保持有界，只接受固定动作与包元数据。 */
class LockDiagnosticBufferTest {
    @Test fun should_keepNewest400_when_manySwitchesArrive() {
        val buffer = LockDiagnosticBuffer()
        repeat(500) { buffer.append(LockDiagnosticEntry(it.toLong(), it * 3000L, LockDiagnosticAction.BLOCK, "app.$it", 1)) }
        assertEquals(400, buffer.entries().size)
        assertEquals(100L, buffer.entries().first().wall)
        assertEquals(499L, buffer.entries().last().wall)
    }

    @Test fun should_coalesceRepeatedMetadata_when_withinTwoSeconds() {
        val buffer = LockDiagnosticBuffer()
        buffer.append(LockDiagnosticEntry(1, 1, LockDiagnosticAction.BLOCK, "app.demo", 1))
        buffer.append(LockDiagnosticEntry(2, 2001, LockDiagnosticAction.BLOCK, "app.demo", 1))
        assertEquals(2, buffer.entries().single().count)
        buffer.append(LockDiagnosticEntry(3, 5000, LockDiagnosticAction.BLOCK, "app.demo", 1))
        assertEquals(2, buffer.entries().size)
    }

    @Test fun should_stripInvalidPackage_when_inputIsNotMetadata() {
        val buffer = LockDiagnosticBuffer()
        buffer.append(LockDiagnosticEntry(1, 1, LockDiagnosticAction.BLOCK, "this is window text", 1))
        assertNull(buffer.entries().single().packageName)
        buffer.clear()
        assertTrue(buffer.entries().isEmpty())
    }
}
