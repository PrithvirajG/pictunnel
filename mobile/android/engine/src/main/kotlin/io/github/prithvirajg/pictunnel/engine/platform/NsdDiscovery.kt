package io.github.prithvirajg.pictunnel.engine.platform

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/** A PicTunnel server found on the LAN; TXT keys per the server's responder: `sid`, `v`, `api`, `fp16`. */
data class DiscoveredServer(
    val name: String,
    val host: String,
    val port: Int,
    val serverId: String?,
    val version: String?,
    val apiVersion: String?,
    /** The first 16 characters of the certificate fingerprint, for the user to compare. */
    val fp16: String?,
) {
    /** The URL manual setup offers (M§4.4); IPv6 literals are bracketed. */
    val url: String get() = if (host.contains(':')) "https://[$host]:$port" else "https://$host:$port"

    companion object {
        fun from(
            name: String,
            host: String,
            port: Int,
            txt: Map<String, ByteArray?>,
        ): DiscoveredServer {
            fun t(k: String) = txt[k]?.toString(Charsets.UTF_8)?.takeIf { it.isNotEmpty() }
            return DiscoveredServer(name, host.trimStart('/'), port, t("sid"), t("v"), t("api"), t("fp16"))
        }
    }
}

/**
 * mDNS discovery of `_pictunnel._tcp` for manual setup (M§4.4), with
 * [NsdManager]. [discover] emits the current list of resolved servers until
 * the collector stops. Resolves run one at a time (older NsdManager versions
 * refuse a second concurrent resolve).
 */
class NsdDiscovery(
    context: Context,
) {
    private val nsd = context.getSystemService(NsdManager::class.java)

    @Suppress("DEPRECATION") // NsdServiceInfo.host: hostAddresses needs API 34.
    fun discover(): Flow<List<DiscoveredServer>> =
        callbackFlow {
            val found = LinkedHashMap<String, DiscoveredServer>()
            val toResolve = Channel<NsdServiceInfo>(Channel.UNLIMITED)

            val listener =
                object : NsdManager.DiscoveryListener {
                    override fun onDiscoveryStarted(serviceType: String) = Unit

                    override fun onDiscoveryStopped(serviceType: String) = Unit

                    override fun onStartDiscoveryFailed(
                        serviceType: String,
                        errorCode: Int,
                    ) {
                        close(IllegalStateException("mDNS discovery failed ($errorCode)"))
                    }

                    override fun onStopDiscoveryFailed(
                        serviceType: String,
                        errorCode: Int,
                    ) = Unit

                    override fun onServiceFound(info: NsdServiceInfo) {
                        toResolve.trySend(info)
                    }

                    override fun onServiceLost(info: NsdServiceInfo) {
                        val snapshot = synchronized(found) { found.remove(info.serviceName)?.let { found.values.toList() } }
                        if (snapshot != null) trySend(snapshot)
                    }
                }

            launch(Dispatchers.Default) {
                for (info in toResolve) {
                    val resolved = withTimeoutOrNull(RESOLVE_TIMEOUT_MS) { resolve(info) } ?: continue
                    val host = resolved.host?.hostAddress ?: continue
                    val server = DiscoveredServer.from(resolved.serviceName, host, resolved.port, resolved.attributes)
                    send(synchronized(found) { found[resolved.serviceName] = server; found.values.toList() })
                }
            }

            send(emptyList())
            nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
            awaitClose {
                toResolve.close()
                runCatching { nsd.stopServiceDiscovery(listener) }
            }
        }

    @Suppress("DEPRECATION") // resolveService works on every supported API level; one resolve at a time.
    private suspend fun resolve(info: NsdServiceInfo): NsdServiceInfo? {
        val done = CompletableDeferred<NsdServiceInfo?>()
        nsd.resolveService(
            info,
            object : NsdManager.ResolveListener {
                override fun onResolveFailed(
                    serviceInfo: NsdServiceInfo,
                    errorCode: Int,
                ) {
                    done.complete(null)
                }

                override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                    done.complete(serviceInfo)
                }
            },
        )
        return done.await()
    }

    companion object {
        const val SERVICE_TYPE = "_pictunnel._tcp"
        private const val RESOLVE_TIMEOUT_MS = 5_000L
    }
}
