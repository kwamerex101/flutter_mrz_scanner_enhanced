package io.github.elmehdaouiahmed.flutter_mrz_scanner_enhanced

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class PreprocessingFailureLatchTest {

    @Test
    fun `below threshold does not fire`() {
        val latch = PreprocessingFailureLatch(threshold = 3)
        assertFalse(latch.recordFailure()) // 1
        assertFalse(latch.recordFailure()) // 2
        assertFalse(latch.hasFired)
    }

    @Test
    fun `fires exactly once at threshold`() {
        val latch = PreprocessingFailureLatch(threshold = 3)
        assertFalse(latch.recordFailure()) // 1
        assertFalse(latch.recordFailure()) // 2
        assertTrue(latch.recordFailure())  // 3 -> fire
        assertTrue(latch.hasFired)
    }

    @Test
    fun `stays latched after firing`() {
        val latch = PreprocessingFailureLatch(threshold = 2)
        assertFalse(latch.recordFailure())
        assertTrue(latch.recordFailure()) // fire
        // Subsequent failures must never re-fire.
        assertFalse(latch.recordFailure())
        assertFalse(latch.recordFailure())
    }

    @Test
    fun `success resets the consecutive run but not the latch`() {
        val latch = PreprocessingFailureLatch(threshold = 3)
        latch.recordFailure() // 1
        latch.recordFailure() // 2
        latch.recordSuccess() // run cleared
        assertFalse(latch.recordFailure()) // 1 again
        assertFalse(latch.recordFailure()) // 2
        assertFalse(latch.hasFired)
        assertTrue(latch.recordFailure())  // 3 -> fire
    }

    @Test
    fun `reset re-arms for a new session`() {
        val latch = PreprocessingFailureLatch(threshold = 2)
        latch.recordFailure()
        assertTrue(latch.recordFailure()) // fire
        assertTrue(latch.hasFired)

        latch.reset()
        assertFalse(latch.hasFired)
        // Must be able to fire again after reset (retry that also fails).
        assertFalse(latch.recordFailure())
        assertTrue(latch.recordFailure())
    }

    @Test(expected = IllegalArgumentException::class)
    fun `rejects non-positive threshold`() {
        PreprocessingFailureLatch(threshold = 0)
    }

    @Test
    fun `concurrent failures fire exactly once`() {
        val threshold = 50
        val latch = PreprocessingFailureLatch(threshold = threshold)
        val threads = 8
        val perThread = 100
        val fireCount = AtomicInteger(0)
        val pool = Executors.newFixedThreadPool(threads)
        val start = CountDownLatch(1)
        val done = CountDownLatch(threads)
        repeat(threads) {
            pool.submit {
                start.await()
                repeat(perThread) {
                    if (latch.recordFailure()) fireCount.incrementAndGet()
                }
                done.countDown()
            }
        }
        start.countDown()
        done.await(5, TimeUnit.SECONDS)
        pool.shutdown()
        // Across all threads, recordFailure() must return true exactly once.
        assertEquals(1, fireCount.get())
        assertTrue(latch.hasFired)
    }
}
