package io.github.prithvirajg.pictunnel

import android.os.Bundle
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.github.prithvirajg.pictunnel.engine.bridge.AndroidHostBackend
import io.github.prithvirajg.pictunnel.engine.bridge.EngineEventsApi
import io.github.prithvirajg.pictunnel.engine.bridge.EngineHost
import io.github.prithvirajg.pictunnel.engine.bridge.EngineHostApi
import io.github.prithvirajg.pictunnel.engine.bridge.EngineServices
import io.github.prithvirajg.pictunnel.engine.platform.DeleteDialog

/**
 * Hosts the Flutter UI and registers the engine bridge (M§3). A
 * [FlutterFragmentActivity] so it has an activity-result registry: free up
 * space shows the system delete dialog through [DeleteDialog], registered in
 * [onCreate] so a dialog result survives activity recreation.
 */
class MainActivity : FlutterFragmentActivity() {
    private var host: EngineHost? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        DeleteDialog.register(this)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val services = EngineServices.get(this)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        val h = EngineHost(AndroidHostBackend(this, services) { DeleteDialog.takeIf { it.attached } })
        host = h
        EngineHostApi.setUp(messenger, h)
        services.relay.attach(EngineEventsApi(messenger))
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        EngineHostApi.setUp(messenger, null)
        EngineServices.get(this).relay.detach()
        host?.close()
        host = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
