package io.github.nanomuse.models

import com.openminis.app.data.model.ProviderCredential
import com.openminis.app.data.model.ProviderInstance
import com.openminis.app.data.model.ProviderType
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** 刷新结果只接受发起请求时的实例与凭证，删除或更换连接后的迟到结果必须丢弃。 */
class ProviderRefreshSnapshotTest {
    private fun instance() = ProviderInstance(
        id = "provider", label = "Local", providerType = ProviderType.openAI,
        credentialType = ProviderCredential.apiKey, customBaseURL = "https://original.test", createdAt = 1,
    )

    @Test fun should_acceptUnchangedProvider_andRejectDeletedOrRecreatedIdentity() {
        val original = instance()
        val snapshot = ProviderRefreshSnapshot(original, "fixture")
        assertTrue(snapshot.matches(original.copy(), "fixture"))
        assertFalse(snapshot.matches(null, "fixture"))
        assertFalse(snapshot.matches(original.copy(createdAt = 2), "fixture"))
        assertFalse(snapshot.matches(original.copy(id = "another"), "fixture"))
    }

    @Test fun should_rejectLateResponse_when_connectionOrCredentialChanges() {
        val original = instance()
        val snapshot = ProviderRefreshSnapshot(original, "fixture")
        listOf(
            original.copy(customBaseURL = "https://replacement.test"),
            original.copy(appendV1Suffix = false),
            original.copy(customUserAgent = "replacement-agent"),
            original.copy(useResponsesAPI = true),
            original.copy(isEnabled = false),
            original.copy(credentialType = ProviderCredential.oauth),
        ).forEach { assertFalse(snapshot.matches(it, "fixture")) }
        assertFalse(snapshot.matches(original, "replacement-key"))
        assertFalse(snapshot.matches(original, null))
    }

    @Test fun should_copyMutableInstance_when_requestSnapshotIsCaptured() {
        val original = instance()
        val snapshot = ProviderRefreshSnapshot(original, "fixture")
        original.customBaseURL = "https://changed-in-place.test"
        assertFalse(snapshot.matches(original, "fixture"))
        assertTrue(snapshot.matches(instance(), "fixture"))
    }

    @Test fun should_acceptUnchangedKeylessRequest_andRejectNewCredential() {
        val original = instance()
        val snapshot = ProviderRefreshSnapshot(original, "")
        assertTrue(snapshot.matches(original, ""))
        assertFalse(snapshot.matches(original, "new-key"))
        val uncredentialed = ProviderRefreshSnapshot(original, null)
        assertTrue(uncredentialed.matches(original, null))
        assertFalse(uncredentialed.matches(original, "new-key"))
    }
}
