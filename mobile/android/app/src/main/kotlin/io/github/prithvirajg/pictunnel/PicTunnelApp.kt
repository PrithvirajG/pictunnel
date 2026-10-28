package io.github.prithvirajg.pictunnel

import android.app.Application
import io.github.prithvirajg.pictunnel.engine.bridge.EngineServices

/** Installs the engine for background work (workers, the upload service) before any component runs. */
class PicTunnelApp : Application() {
    override fun onCreate() {
        super.onCreate()
        EngineServices.installRuntime(this)
    }
}
