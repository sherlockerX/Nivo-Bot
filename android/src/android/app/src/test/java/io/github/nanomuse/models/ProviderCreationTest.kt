package io.github.nanomuse.models

import com.openminis.app.data.model.ProviderCredential
import com.openminis.app.data.model.ProviderInstance
import com.openminis.app.data.model.ProviderType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

/** 验证新增供应商在凭证失败、配置失败与无密钥重试时的提交边界。 */
class ProviderCreationTest {
    private val instance = ProviderInstance(
        id = "pending-provider", label = "Local", providerType = ProviderType.openAI,
        credentialType = ProviderCredential.apiKey, customBaseURL = "https://example.test",
    )

    @Test
    fun `credential failure never exposes a configured provider`() {
        var configWrites = 0
        assertThrows(IllegalStateException::class.java) {
            ProviderCreation.save(instance, "fixture", { _, _ -> false }, { configWrites++ })
        }
        assertEquals(0, configWrites)
    }

    @Test
    fun `configuration failure is reported and retry uses the same identity`() {
        val credentialIds = mutableListOf<String>()
        var storedKey: String? = null
        val commitCredential: (String, String?) -> Boolean = { id, key ->
            credentialIds += id
            storedKey = key
            true
        }
        assertThrows(IllegalStateException::class.java) {
            ProviderCreation.save(instance, " fixture ", commitCredential, { error("disk") })
        }
        assertEquals("fixture", storedKey)
        val instances = mutableListOf<ProviderInstance>()
        ProviderCreation.save(instance, "new fixture", commitCredential, { instances += it })
        assertEquals(listOf(instance.id, instance.id), credentialIds)
        assertEquals(listOf(instance), instances)
        assertEquals("new fixture", storedKey)
    }

    @Test
    fun `keyless retry clears a staged credential before exposing configuration`() {
        var stagedKey: String? = "fixture"
        ProviderCreation.save(instance, " ", { id, key ->
            assertEquals(instance.id, id)
            stagedKey = key
            true
        }, { assertNull(stagedKey) })
        assertNull(stagedKey)
    }

    @Test
    fun `restored form cannot replace the credentials or endpoint of a completed submission`() {
        val didCreate = ProviderCreation.save(
            instance.copy(customBaseURL = null), "",
            commitCredential = { _, _ -> error("must preserve saved credentials") },
            commitInstance = { error("must preserve saved endpoint") },
            isAlreadySaved = { true },
        )
        assertEquals(false, didCreate)
    }
}
