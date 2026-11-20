package io.github.nanomuse.local

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** 验证停用内置服务时保留个人供应商与历史数据归属。 */
class LocalOnlyPolicyTest {
    @Test fun `原云实例在自建中继地址下仍被停用`() {
        assertTrue(LocalOnlyPolicy.isRetiredProvider("legacy", "https://private.example/v1", "legacy"))
    }

    @Test fun `导入的原官方中继实例也不能重新联网`() {
        assertTrue(LocalOnlyPolicy.isRetiredProvider("imported", "https://CLOUD.NANOMUSE.CN/v1", null))
    }

    @Test fun `官方中继域名尾部DNS根点不能绕过停用规则`() {
        listOf("https://cloud.nanomuse.cn./v1", "https://CLOUD.NANOMUSE.CN./v1").forEach {
            assertTrue(LocalOnlyPolicy.isRetiredProvider("imported", it, null))
        }
    }

    @Test fun `用户第三方API和本地服务器继续可用`() {
        listOf("https://api.openai.com/v1", "https://my-relay.example/v1", "https://my-relay.example./v1", "http://127.0.0.1:11434/v1", null).forEach {
            assertFalse(LocalOnlyPolicy.isRetiredProvider("own", it, "legacy"))
        }
    }

    @Test fun `相似域名不被误判为原云服务`() {
        assertFalse(LocalOnlyPolicy.isRetiredProvider("own", "https://cloud.nanomuse.cn.example/v1", null))
        assertFalse(LocalOnlyPolicy.isRetiredProvider("own", "https://cloud.nanomuse.cn.example.com/v1", null))
        assertFalse(LocalOnlyPolicy.isRetiredProvider("own", "https://example.org/cloud.nanomuse.cn", null))
    }

    @Test fun `已有本地归属包括空标识不受旧账号残留覆盖`() {
        assertEquals("", LocalOnlyPolicy.owner("", "old-account", "old-token"))
        assertEquals("saved-owner", LocalOnlyPolicy.owner("saved-owner", "old-account", null))
    }

    @Test fun `首次本地化保留原账号及旧版令牌哈希归属`() {
        assertEquals("old-account", LocalOnlyPolicy.owner(null, "old-account", "token"))
        assertEquals("token".hashCode().toString(), LocalOnlyPolicy.owner(null, null, "token"))
        assertEquals("", LocalOnlyPolicy.owner(null, null, null))
    }
}
