package io.github.nanomuse.chat

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** nanoMuse: 外部发送和预填都必须保留尚未提交的输入状态。 */
class ExternalPromptPolicyTest {
    @Test
    fun should_protectComposer_when_onlyEditingTargetExists() {
        assertTrue(ExternalPromptPolicy.shouldProtect("", "message-id", false, false))
    }

    @Test
    fun should_protectComposer_when_onlyAttachmentsExist() {
        assertTrue(ExternalPromptPolicy.shouldProtect("", null, true, false))
    }

    @Test
    fun should_protectComposer_when_onlyPastedTextsExist() {
        assertTrue(ExternalPromptPolicy.shouldProtect("", null, false, true))
    }

    @Test
    fun should_protectComposer_when_unsentTextExists() {
        assertTrue(ExternalPromptPolicy.shouldProtect("尚未发送的草稿", null, false, false))
    }

    @Test
    fun should_protectComposer_when_inputContainsOnlyWhitespace() {
        assertTrue(ExternalPromptPolicy.shouldProtect(" \n", null, false, false))
    }

    @Test
    fun should_allowExternalPrompt_when_composerIsEmpty() {
        assertFalse(ExternalPromptPolicy.shouldProtect("", null, false, false))
    }

    @Test
    fun should_protectComposer_when_multiplePendingStatesExist() {
        assertTrue(ExternalPromptPolicy.shouldProtect("修改中的草稿", "message-id", true, true))
    }
}
