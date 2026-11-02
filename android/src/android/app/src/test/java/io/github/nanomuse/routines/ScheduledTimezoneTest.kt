package io.github.nanomuse.routines

import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.DataOutputStream

/** 使用合成归档验证固定索引和越界拒绝，不依赖电脑时区数据库。 */
class ScheduledTimezoneTest {
    @get:Rule val temporary = TemporaryFolder()

    private fun archive(length: Int = 44): java.io.File = temporary.newFile().also { file ->
        DataOutputStream(file.outputStream()).use { output ->
            output.write("tzdata2025b\u0000".toByteArray(Charsets.US_ASCII))
            output.writeInt(24); output.writeInt(76); output.writeInt(120)
            output.write("Asia/Shanghai".toByteArray(Charsets.US_ASCII).copyOf(40))
            output.writeInt(0); output.writeInt(length); output.writeInt(28800)
            output.write("TZif".toByteArray(Charsets.US_ASCII)); output.write(ByteArray(40))
        }
    }

    @Test fun should_extractOnlyNamedZone_when_archiveIsValid() {
        val file = archive()
        val bytes = requireNotNull(ScheduledTimezone.extract(file, "Asia/Shanghai"))
        assertEquals(44, bytes.size)
        assertEquals("TZif", String(bytes, 0, 4, Charsets.US_ASCII))
        assertNull(ScheduledTimezone.extract(file, "America/Chicago"))
    }

    @Test fun should_rejectOutOfBoundsEntry_when_archiveClaimsMoreBytes() {
        assertThrows(IllegalArgumentException::class.java) { ScheduledTimezone.extract(archive(45), "Asia/Shanghai") }
    }
}
