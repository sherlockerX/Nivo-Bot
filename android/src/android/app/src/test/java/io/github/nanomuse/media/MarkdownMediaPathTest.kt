package io.github.nanomuse.media

import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

/** 媒体路径策略只使用明确归属，不按文件名猜测会话。 */
class MarkdownMediaPathTest {
    @Test fun should_keepMissingFileInOwningSession_when_otherSessionHasSameName() {
        val root = Files.createTempDirectory("media-path").toFile()
        try {
            File(root, "minis-sessions/B/attachments/result.wav").apply {
                parentFile.mkdirs(); writeText("fixture")
            }
            val resolved = MarkdownMediaPath.resolve(root, "minis://attachments/result.wav", "A")
            assertEquals(File(root, "minis-sessions/A/attachments/result.wav"), resolved)
            assertFalse(resolved!!.exists())
        } finally { root.deleteRecursively() }
    }

    @Test fun should_followActualDraftAlias_when_mappingExists() {
        val root = File("fixture")
        val path = MarkdownMediaPath.resolve(root, "minis://workspace/nested/a.txt", "__new__draft") {
            if (it == "__new__draft") "canonical" else it
        }
        assertEquals(File(root, "minis-sessions/canonical/workspace/nested/a.txt"), path)
    }

    @Test fun should_preserveHashPlusAndDecodeOnce_when_urlEncoded() {
        val root = File("fixture")
        assertEquals(File(root, "minis-sessions/A/attachments/a+#中%23.png"),
            MarkdownMediaPath.resolve(root, "minis://attachments/a+%23%E4%B8%AD%2523.png?download=1", "A"))
        assertEquals(File(root, "minis-sessions/A/attachments/a#b.png"),
            MarkdownMediaPath.resolve(root, "minis://attachments/a#b.png", "A"))
    }

    @Test fun should_rejectTraversalUnknownOwnerAndMalformedEncoding() {
        val root = File("fixture")
        listOf("minis://attachments/../B/file", "minis://attachments/%2e%2e/file",
            "minis://attachments/%zz", "minis://attachments/..\\B\\file").forEach {
            assertNull(MarkdownMediaPath.resolve(root, it, "A"))
        }
        assertNull(MarkdownMediaPath.resolve(root, "minis://attachments/a.png", null))
        assertNull(MarkdownMediaPath.resolve(root, "minis://attachments/a.png", "../B"))
    }

    @Test fun should_allowExplicitSharedDirectory_withoutSession() {
        assertEquals(File("fixture/minis-global/shared/a+b#c.png"),
            MarkdownMediaPath.resolve(File("fixture"), "minis://shared/a+b#c.png", null))
    }

    @Test fun should_preserveAbsoluteFilePaths_when_filenameContainsReservedCharacters() {
        assertEquals(File("/tmp/a+b#c.png"),
            MarkdownMediaPath.resolve(File("fixture"), "file:///tmp/a+b%23c.png", "A"))
        assertEquals(File("/tmp/a+b#c.png"),
            MarkdownMediaPath.resolve(File("fixture"), "/tmp/a+b#c.png", "A"))
    }

    @Test fun should_resolveExplicitMount_when_actualSessionAndBindingExist() {
        val calls = mutableListOf<Pair<String, String>>()
        val resolved = MarkdownMediaPath.resolveMounted(
            "minis://mounts/photos/a+%23%E4%B8%AD.png", "draft", { "actual" },
        ) { owner, path ->
            calls += owner to path
            File("bound/photos/a+#中.png")
        }
        assertEquals(File("bound/photos/a+#中.png"), resolved)
        assertEquals(listOf("actual" to "/var/minis/mounts/photos/a+#中.png"), calls)
    }

    @Test fun should_notGuessMount_when_noSessionTraversalOrUnknownBinding() {
        var calls = 0
        listOf("minis://mounts/photos/../private.png", "minis://attachments/a.png",
            "minis://mounts/photos/%zz").forEach { url ->
            assertNull(MarkdownMediaPath.resolveMounted(url, "actual") { _, _ -> calls++; File("bad") })
        }
        assertNull(MarkdownMediaPath.resolveMounted("minis://mounts/photos/a.png", null) { _, _ -> calls++; File("bad") })
        assertEquals(0, calls)
        assertNull(MarkdownMediaPath.resolveMounted("/var/minis/mounts/missing/a.png", "actual") { _, _ -> null })
    }
}
