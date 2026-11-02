package io.github.nanomuse.routines

import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.Base64

/** 使用真实子进程验证EOF、退出码、分离管道和取消，不依赖proot或用户脚本。 */
class ScheduledProcessTest {
    private fun command(vararg arguments: String): ProcessBuilder {
        val java = File(System.getProperty("java.home"), "bin/java" + if (System.getProperty("os.name").orEmpty().startsWith("Windows")) ".exe" else "")
        val classpath = File(requireNotNull(ScheduledProcessFixture::class.java.protectionDomain?.codeSource).location.toURI()).absolutePath
        return ProcessBuilder(listOf(java.absolutePath, "-cp", classpath, ScheduledProcessFixture::class.java.name) + arguments).apply {
            environment().remove("JAVA_TOOL_OPTIONS"); environment().remove("JDK_JAVA_OPTIONS"); environment().remove("_JAVA_OPTIONS")
        }
    }

    @Test fun should_captureLastBytesAndSeparateStderr_when_processExits() = runBlocking {
        val result = ScheduledProcess.capture(command("mixed"), 5000)
        assertEquals("FIRSTLAST", result.stdout)
        assertEquals("STDERR_ONLY", result.stderrTail)
        assertEquals(9L, result.stdoutBytes)
        assertEquals(0, result.exitCode)
        assertNull(result.captureError)
    }

    @Test fun should_deliverOneLiteralArgument_when_textContainsShellSyntax() = runBlocking {
        val argument = "a b; rm -rf /"
        val result = ScheduledProcess.capture(command("args", argument, "am", ""), 5000)
        val expected = listOf(argument, "am", "").map { Base64.getEncoder().encodeToString(it.toByteArray(Charsets.UTF_8)) }
        assertEquals(expected, result.stdout.replace("\r\n", "\n").removeSuffix("\n").split("\n"))
    }

    @Test fun should_countAndHashAllBytes_when_captureBodyIsBounded() = runBlocking {
        val result = ScheduledProcess.capture(command("large"), 5000)
        assertEquals(200000L, result.stdoutBytes)
        assertEquals(128 * 1024, result.stdout.toByteArray().size)
        assertTrue(result.truncated)
        val hash = MessageDigest.getInstance("SHA-256").digest("x".repeat(200000).toByteArray()).joinToString("") { "%02x".format(it.toInt() and 255) }
        assertEquals(hash, result.stdoutSha256)
    }

    @Test fun should_preserveActualExitAndPartialOutput_when_scriptFails() = runBlocking {
        val result = ScheduledProcess.capture(command("failure"), 5000)
        assertEquals(7, result.exitCode)
        assertEquals("BEFORE_FAILURE", result.stdout)
    }

    @Test fun should_cancelWithoutWaitingForSlowChild_when_parentIsCancelled() = runBlocking {
        val start = System.nanoTime()
        assertNull(withTimeoutOrNull(300) { ScheduledProcess.capture(command("slow"), 30000) })
        assertTrue((System.nanoTime() - start) / 1_000_000 < 3000)
    }

    @Test fun should_drainEveryConcurrentProcess_when_capacityExceedsFour() = runBlocking {
        val results = (1..8).map { async { ScheduledProcess.capture(command("mixed"), 10000) } }.awaitAll()
        results.forEach { result ->
            assertEquals(0, result.exitCode)
            assertEquals("FIRSTLAST", result.stdout)
            assertEquals("STDERR_ONLY", result.stderrTail)
            assertNull(result.captureError)
        }
    }

    @Test fun should_deliverStdinEof_when_taskHasNoInput() = runBlocking {
        val result = ScheduledProcess.capture(command("stdin"), 3000)
        assertEquals(0, result.exitCode)
        assertEquals("EOF", result.stdout)
    }

    @Test fun should_preserveAll719Bytes_when_capturing250SyntheticRuns() = runBlocking {
        repeat(25) {
            (1..10).map { async { ScheduledProcess.capture(command("payload"), 15000) } }.awaitAll().forEach { result ->
                assertEquals(0, result.exitCode)
                assertEquals(719L, result.stdoutBytes)
                assertEquals("x".repeat(719), result.stdout)
                assertFalse(result.truncated)
                assertNull(result.captureError)
            }
        }
    }
}
