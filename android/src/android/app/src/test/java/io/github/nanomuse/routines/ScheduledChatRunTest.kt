package io.github.nanomuse.routines

import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

/** 固定父句柄覆盖挂起准备与后续执行，不依赖UI布尔值。 */
@OptIn(ExperimentalCoroutinesApi::class)
class ScheduledChatRunTest {
    @Test fun should_waitForTailLaunchedAfterSuspension_when_setupIsSealed() = runTest {
        val run = ScheduledChatRun(coroutineContext[Job])
        var finished = false
        run.launch(this) {
            delay(100)
            run.launch(this@runTest) { delay(500); finished = true }
        }
        run.seal()
        assertTrue(run.hasStarted)
        assertFalse(run.job.isCompleted)
        run.job.join()
        assertTrue(finished)
        assertFalse(run.job.isCancelled)
    }

    @Test fun should_cancelPreparationAndTail_when_userStopsStableHandle() = runTest {
        val run = ScheduledChatRun(coroutineContext[Job])
        var tailStarted = false
        run.launch(this) { delay(1000); tailStarted = true }
        run.seal()
        run.job.cancelAndJoin()
        assertTrue(run.job.isCancelled)
        assertFalse(tailStarted)
    }
}
