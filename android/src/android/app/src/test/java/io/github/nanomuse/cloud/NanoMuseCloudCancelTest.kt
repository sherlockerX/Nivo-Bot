package io.github.nanomuse.cloud

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** 验证旧云入口不再联网，且本地化保留原有数据归属。 */
class NanoMuseCloudCancelTest {

    /** A context whose preferences live in a map: enough for [NanoMuseCloud.baseUrl]. */
    private class PrefsContext : ContextWrapper(null) {
        private val stores = mutableMapOf<String, MapPrefs>()
        override fun getSharedPreferences(name: String, mode: Int): SharedPreferences = stores.getOrPut(name) { MapPrefs() }
        override fun getApplicationContext(): Context = this
    }

    private class MapPrefs : SharedPreferences {
        val values = mutableMapOf<String, Any?>()
        override fun getAll(): MutableMap<String, *> = values
        override fun getString(key: String, defValue: String?): String? = values[key] as? String ?: defValue
        override fun getStringSet(key: String, defValues: MutableSet<String>?): MutableSet<String>? =
            @Suppress("UNCHECKED_CAST") (values[key] as? MutableSet<String>) ?: defValues
        override fun getInt(key: String, defValue: Int): Int = values[key] as? Int ?: defValue
        override fun getLong(key: String, defValue: Long): Long = values[key] as? Long ?: defValue
        override fun getFloat(key: String, defValue: Float): Float = values[key] as? Float ?: defValue
        override fun getBoolean(key: String, defValue: Boolean): Boolean = values[key] as? Boolean ?: defValue
        override fun contains(key: String): Boolean = values.containsKey(key)
        override fun edit(): SharedPreferences.Editor = Editor()
        override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) {}
        override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) {}

        inner class Editor : SharedPreferences.Editor {
            private val pending = mutableMapOf<String, Any?>()
            private val removed = mutableSetOf<String>()
            private var clearAll = false
            override fun putString(key: String, value: String?) = apply { pending[key] = value }
            override fun putStringSet(key: String, values: MutableSet<String>?) = apply { pending[key] = values }
            override fun putInt(key: String, value: Int) = apply { pending[key] = value }
            override fun putLong(key: String, value: Long) = apply { pending[key] = value }
            override fun putFloat(key: String, value: Float) = apply { pending[key] = value }
            override fun putBoolean(key: String, value: Boolean) = apply { pending[key] = value }
            override fun remove(key: String) = apply { removed += key }
            override fun clear() = apply { clearAll = true }
            override fun commit(): Boolean { apply(); return true }
            override fun apply() {
                if (clearAll) values.clear()
                removed.forEach { values.remove(it) }
                values.putAll(pending)
            }
        }
    }

    @Test fun `原云登录接口在发送请求前本地拒绝`() = runBlocking {
        MockWebServer().use { server ->
            val context = PrefsContext()
            NanoMuseCloud.setBaseUrl(context, server.url("/").toString())
            val requests: List<suspend () -> Unit> = listOf(
                { NanoMuseCloud.requestCode(context, "someone") },
                { NanoMuseCloud.verify(context, "someone", "123456") },
                { NanoMuseCloud.login(context, "someone", "test-password") },
                { NanoMuseCloud.checkRelay(server.url("/").toString()) },
            )
            for (request in requests) {
                try {
                    request()
                    fail("The retired service must be rejected locally")
                } catch (expected: IllegalStateException) {
                    assertTrue(expected.message.orEmpty().contains("unavailable"))
                }
            }
            assertEquals(0, server.requestCount)
            assertFalse(NanoMuseCloud.isSignedIn(context))
            assertNull(NanoMuseCloud.apiKey(context))
        }
    }

    @Test fun `旧账号升级固定owner且退出接口不删除资料偏好`() = runBlocking {
        val context = PrefsContext()
        val prefs = context.getSharedPreferences("nanomuse", Context.MODE_PRIVATE)
        prefs.edit().putString("cloud.account_id", "previous-owner")
            .putString("main_chat.session", "saved-chat").commit()
        assertEquals("previous-owner", io.github.nanomuse.local.LocalOnlyMode.owner(context))
        prefs.edit().remove("cloud.account_id").commit()
        assertEquals("previous-owner", io.github.nanomuse.local.LocalOnlyMode.owner(context))
        try {
            NanoMuseCloud.signOut(context, keep = false)
            fail("A local build must not execute the old account deletion flow")
        } catch (expected: IllegalStateException) {
            assertTrue(expected.message.orEmpty().contains("unavailable"))
        }
        assertEquals("saved-chat", prefs.getString("main_chat.session", null))
        assertEquals("previous-owner", io.github.nanomuse.local.LocalOnlyMode.owner(context))
    }

    @Test fun `恢复配置只冻结旧云实例而保留模型归属和个人供应商`() {
        val context = PrefsContext()
        context.getSharedPreferences("nanomuse", Context.MODE_PRIVATE).edit()
            .putString("cloud.instance_id", "legacy").commit()
        val legacy = com.openminis.app.data.model.ProviderInstance(
            id = "legacy", label = "Old account",
            providerType = com.openminis.app.data.model.ProviderType.openAI,
            credentialType = com.openminis.app.data.model.ProviderCredential.apiKey,
            customBaseURL = "https://private-relay.example/v1",
        )
        val own = legacy.copy(id = "own", label = "My API", customBaseURL = "https://api.example/v1")
        val config = com.openminis.app.data.model.ProviderConfig(
            instances = mutableListOf(legacy, own), defaultPrimaryGroupId = "saved-group",
        )
        val frozen = io.github.nanomuse.local.LocalOnlyMode.freezeCloudProviders(context, config)
        assertEquals(listOf("legacy", "own"), frozen.instances.map { it.id })
        assertFalse(frozen.instances[0].isEnabled)
        assertTrue(frozen.instances[1].isEnabled)
        assertTrue(legacy.isEnabled)
        assertEquals("saved-group", frozen.defaultPrimaryGroupId)
        assertEquals(config.modelEntries, frozen.modelEntries)
        assertEquals(config.modelGroups, frozen.modelGroups)
    }
}
