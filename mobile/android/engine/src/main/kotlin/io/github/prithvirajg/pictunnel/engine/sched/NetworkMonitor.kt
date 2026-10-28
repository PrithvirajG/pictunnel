package io.github.prithvirajg.pictunnel.engine.sched

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Watches the default network. When it changes, the engine goes back to the
 * LAN-first endpoint order (R9), a certificate pause is cleared (captive
 * portals), and a sync is requested. The network active at registration
 * is the baseline, so the callback's first report of it changes nothing.
 */
object NetworkMonitor {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var registered = false

    @Volatile private var current: Network? = null

    @Synchronized
    fun register(context: Context) {
        if (registered) return
        registered = true
        val app = context.applicationContext
        val cm = app.getSystemService(ConnectivityManager::class.java)
        current = cm.activeNetwork
        cm.registerDefaultNetworkCallback(
            object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    if (network == current) return
                    current = network
                    scope.launch { runCatching { EngineRuntime.onNetworkChanged(app) } }
                }

                override fun onLost(network: Network) {
                    if (network != current) return
                    current = null
                    scope.launch { runCatching { EngineRuntime.engine(app)?.onNetworkChanged() } }
                }
            },
        )
    }
}
