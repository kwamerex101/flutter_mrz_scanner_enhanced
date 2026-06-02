package io.github.elmehdaouiahmed.flutter_mrz_scanner_enhanced

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * Tracks consecutive camera-frame preprocessing failures and fires exactly
 * once when a run of [threshold] failures is reached, until [reset].
 *
 * Why this exists: a single bad frame is dropped silently (transient), but a
 * *systematic* failure (e.g. a device whose NV21 buffer geometry the live
 * path can't handle) would otherwise drop every frame forever — `onParsed`
 * never fires and the user hangs on "Scanning…" with no error surfaced. This
 * latch lets the camera surface a one-shot `onError` after a persistent run.
 *
 * Thread-safety: [recordFailure]/[recordSuccess] run on the Fotoapparat
 * frame-callback thread; [reset] runs on the platform thread (user retry via
 * the "start" method call). Both fields are atomic, and [fired] (set via
 * [java.util.concurrent.atomic.AtomicBoolean.compareAndSet]) is the single
 * source of truth, so the callback fires AT MOST ONCE. The two fields are not
 * reset as one atomic unit, so a [reset] racing a frame-thread call that has
 * already passed the threshold may, in the worst case, fire once on the very
 * first frame of a retry — benign (a spurious error callback, never a missed
 * fire and never a hang). [reset] clears the counter before [fired] to keep
 * that window minimal.
 *
 * Pure (no Android dependencies) so it is unit-testable on a plain JVM.
 */
class PreprocessingFailureLatch(private val threshold: Int = DEFAULT_THRESHOLD) {
    init {
        require(threshold > 0) { "threshold must be > 0, was $threshold" }
    }

    private val consecutiveFailures = AtomicInteger(0)
    private val fired = AtomicBoolean(false)

    /**
     * Record one preprocessing failure. Returns `true` exactly once — on the
     * call that first reaches [threshold] consecutive failures — and `false`
     * on every call after that (latched) until [reset]. The caller should
     * fire `onError` only when this returns `true`.
     */
    fun recordFailure(): Boolean {
        if (fired.get()) return false
        return consecutiveFailures.incrementAndGet() >= threshold &&
            fired.compareAndSet(false, true)
    }

    /**
     * Record a successful preprocess. Clears the consecutive-failure run so a
     * recovered device does not creep toward the threshold over a long
     * session. Deliberately does NOT un-fire the latch: within one scan
     * session we surface the error once and stay quiet. A new session
     * re-arms via [reset].
     */
    fun recordSuccess() {
        consecutiveFailures.set(0)
    }

    /**
     * Full re-arm for a new scan session (user retry / camera "start"). Without
     * this, the reused camera instance would stay latched and a retry would
     * silently hang again.
     */
    fun reset() {
        consecutiveFailures.set(0)
        fired.set(false)
    }

    /** Whether the one-shot error has already fired this session. */
    val hasFired: Boolean get() = fired.get()

    companion object {
        /**
         * ~1 second of dropped frames at 30fps. High enough that a transient
         * burst (camera warm-up, orientation flip) never trips it; low enough
         * that a genuinely broken device surfaces an error within ~1–2s
         * instead of hanging indefinitely.
         */
        const val DEFAULT_THRESHOLD = 30
    }
}
