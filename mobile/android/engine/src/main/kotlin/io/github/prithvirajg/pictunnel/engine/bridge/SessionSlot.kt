package io.github.prithvirajg.pictunnel.engine.bridge

import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext

/**
 * A session built on demand and cached, which [end] retires while the
 * credentials change. While an [end] is in progress [get] returns null: the
 * retire can wait seconds for an in-flight refresh, and a session rebuilt from
 * the credentials about to be wiped would otherwise outlive the wipe (the app
 * would still look paired). [retire] ends one session and runs the block
 * under its refresh lock.
 */
internal class SessionSlot<S : Any>(
    private val build: () -> S?,
    private val retire: suspend (S, suspend () -> Unit) -> Unit,
) {
    private val lock = Any()
    private var current: S? = null
    private var ending = 0

    fun get(): S? =
        synchronized(lock) {
            if (ending > 0) return null
            current ?: build()?.also { current = it }
        }

    fun drop() {
        synchronized(lock) { current = null }
    }

    suspend fun <T> end(block: suspend () -> T): T {
        val old =
            synchronized(lock) {
                ending++
                current.also { current = null }
            }
        try {
            if (old == null) return block()
            var out: Any? = null
            retire(old) { out = block() }
            @Suppress("UNCHECKED_CAST")
            return out as T
        } finally {
            // Nothing can be built while ending; retire anything that slipped in anyway.
            val stray =
                synchronized(lock) {
                    ending--
                    current.also { current = null }
                }
            if (stray != null) withContext(NonCancellable) { retire(stray) {} }
        }
    }
}
