package io.github.nanomuse.sandbox

import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/** 不依赖Windows链接权限即可覆盖Alpine的绝对链接。 */
class GuestExecutableTest {
    @get:Rule val temporary = TemporaryFolder()
    @Test fun should_resolveInsideGuest_when_absoluteLinkUsed() {
        val root = temporary.newFolder()
        File(root, "bin").mkdirs()
        File(root, "bin/busybox").writeText("fixture")
        assertTrue(GuestExecutable.isPresent(root, "/bin/sh") { if (it.name == "sh") "/bin/busybox" else null })
    }
    @Test fun should_reject_when_linkEscapesOrLoops() {
        val root = temporary.newFolder()
        assertFalse(GuestExecutable.isPresent(root, "bin/sh") { "../../outside" })
        assertFalse(GuestExecutable.isPresent(root, "bin/sh") { "/bin/sh" })
    }
}
