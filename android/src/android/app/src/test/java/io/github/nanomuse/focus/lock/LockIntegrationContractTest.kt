package io.github.nanomuse.focus.lock

import org.junit.Assert.*
import org.junit.Test
import java.io.File

/** 上游更新时必须保留唯一转发，同时正式构建不能混入ADB安全出口。 */
class LockIntegrationContractTest {
    private val source = listOf(File("src"), File("app/src")).first { it.isDirectory }

    @Test fun should_keepSingleMetadataForwarder_when_upstreamServiceChanges() {
        val service = File(source, "main/java/com/openminis/app/accessibility/MinisAccessibilityService.kt").readText()
        assertEquals(1, Regex("LockController\\.onAccessibilityEvent\\(").findAll(service).count())
        assertTrue(service.lineSequence().first { "LockController.onAccessibilityEvent" in it }.contains("// nanoMuse:"))
        val controller = File(source, "main/java/io/github/nanomuse/focus/lock/LockController.kt").readText()
        listOf("rootInActiveWindow", "event.text", "contentDescription", ".root").forEach { assertFalse(controller.contains(it)) }
    }

    @Test fun should_excludeDebugExit_when_buildingRelease() {
        val main = File(source, "main/AndroidManifest.xml").readText()
        assertFalse(main.contains("DebugLockReceiver"))
        assertFalse(File(source, "release/AndroidManifest.xml").takeIf { it.exists() }?.readText().orEmpty().contains("DebugLockReceiver"))
        assertFalse(File(source, "main/java/io/github/nanomuse/focus/lock/DebugLockReceiver.kt").exists())
        assertTrue(main.contains("android:foregroundServiceType=\"specialUse\""))
    }
}
