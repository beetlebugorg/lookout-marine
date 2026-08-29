package org.beetlebug.lookout.engine

import org.beetlebug.lookout.Lookout

import android.os.Handler
import android.os.Looper

/**
 * The three things every piece of shell state needs from the engine: the
 * handle, the thread its calls belong on, and the way back to the main thread.
 *
 * THE THREADING RULE THIS OWNS. Every native call belongs on the render thread,
 * because the C ABI's api lock is held for a whole frame and a UI-thread call
 * froze for that long. Compose state belongs on the main thread. So work goes
 * out through [onEngine] and answers come back through [onMain], and nothing
 * that holds shell state has to keep its own copy of that rule or its own
 * handler to enforce it.
 *
 * It exists so the controller can be more than one class. Twelve concerns lived
 * in ChartController because they shared exactly these three things and nothing
 * else; passing this to each of them is what lets them move apart.
 *
 * The handle is null while detached — between the surface going and the next
 * one arriving, and for the whole life of the process before the first open —
 * so [onEngine] drops its block rather than queueing work against nothing.
 */
class EngineAccess {

    @Volatile private var handle: Lookout? = null

    /** The render thread's queue; null while detached. */
    @Volatile private var queue: Handler? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * Set by the engine: wakes its idled frame loop after a mutation lands. A
     * spurious wake — a read posted through [onEngine] — costs one needsRedraw
     * check, which is why every posted block wakes rather than only the ones
     * that write.
     */
    var onMutated: (() -> Unit)? = null

    /** The live handle, or null while detached. RENDER THREAD for anything
     *  that then calls into it. */
    val live: Lookout? get() = handle

    val isOpen: Boolean get() = handle != null

    /**
     * Whether [l] is still the handle this is bound to.
     *
     * Switching chart library closes one engine and opens another, and the
     * outgoing close can land AFTER the incoming open has already bound. A
     * close that did not check would leave the shell detached from a live
     * engine: a frozen HUD and dead settings until the next surface change.
     */
    fun isLive(l: Lookout?): Boolean = l == null || handle === l

    fun bind(l: Lookout, renderQueue: Handler) {
        handle = l
        queue = renderQueue
    }

    fun unbind() {
        queue = null
        handle = null
    }

    /** Run [block] on the render thread against the live handle, or drop it if
     *  there is no engine. Safe to call from any thread. */
    fun onEngine(block: (Lookout) -> Unit) {
        val h = queue ?: return
        h.post {
            handle?.let(block)
            onMutated?.invoke()
        }
    }

    /** Ask for a frame without doing anything to the engine. */
    fun wake() {
        onMutated?.invoke()
    }

    fun onMain(block: () -> Unit) {
        mainHandler.post(block)
    }

    fun postMain(r: Runnable) {
        mainHandler.post(r)
    }

    fun postMainDelayed(delayMs: Long, r: Runnable) {
        mainHandler.postDelayed(r, delayMs)
    }

    fun cancelMain(r: Runnable) {
        mainHandler.removeCallbacks(r)
    }
}
