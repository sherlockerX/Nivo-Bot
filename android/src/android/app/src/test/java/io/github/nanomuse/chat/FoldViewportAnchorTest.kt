package io.github.nanomuse.chat

import org.junit.Assert.*
import org.junit.Test

/** 下一次测量直接保持标题偏移，不经过零偏移的中间位置。 */
class FoldViewportAnchorTest {
    @Test fun should_includeLazyBodyAndBanners_when_expanding() {
        assertEquals(FoldViewportAnchor.Request(5, -650),
            FoldViewportAnchor.requestFor("steps", listOf("reply", "tool2", "tool1", "thought", "steps", "question"), 1, 650))
    }
    @Test fun should_keepSameOffset_when_collapsing() {
        assertEquals(FoldViewportAnchor.Request(2, -650),
            FoldViewportAnchor.requestFor("steps", listOf("reply", "steps", "question"), 1, 650))
    }
    @Test fun should_useCurrentRows_when_streamInsertsAndBannerDisappears() {
        assertEquals(FoldViewportAnchor.Request(4, 35),
            FoldViewportAnchor.requestFor("steps", listOf("new-reply", "new-tool", "tool2", "tool1", "steps"), 0, -35))
    }
    @Test fun should_notJumpToAnotherMessage_when_headerWasRemoved() {
        assertNull(FoldViewportAnchor.requestFor("steps", listOf("other"), 1, 650))
        assertNull(FoldViewportAnchor.requestFor("steps", listOf("steps"), -1, 650))
    }
}
