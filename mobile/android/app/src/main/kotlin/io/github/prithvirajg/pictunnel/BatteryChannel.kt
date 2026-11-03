package io.github.prithvirajg.pictunnel

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * The Settings "Battery optimisation" hint (M§10): whether the app is exempt
 * from battery optimisation, and the system flow that grants the exemption
 * (the direct request dialog, else the battery optimisation settings list).
 * A plain method channel, so the Pigeon bridge stays unchanged.
 */
object BatteryChannel {
    const val NAME = "pictunnel/battery"

    fun attach(
        activity: Activity,
        messenger: BinaryMessenger,
    ) {
        MethodChannel(messenger, NAME).setMethodCallHandler { call, result ->
            when (call.method) {
                "isIgnoringBatteryOptimizations" -> {
                    val pm = activity.getSystemService(PowerManager::class.java)
                    result.success(pm?.isIgnoringBatteryOptimizations(activity.packageName) ?: true)
                }
                "requestIgnoreBatteryOptimizations" -> {
                    result.success(open(activity))
                }
                else -> result.notImplemented()
            }
        }
    }

    fun detach(messenger: BinaryMessenger) {
        MethodChannel(messenger, NAME).setMethodCallHandler(null)
    }

    /** Returns whether a system screen opened. */
    private fun open(activity: Activity): Boolean {
        val direct =
            Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${activity.packageName}"))
        val list = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
        for (intent in listOf(direct, list)) {
            try {
                activity.startActivity(intent)
                return true
            } catch (_: ActivityNotFoundException) {
                // try the next screen
            } catch (_: SecurityException) {
                // try the next screen
            }
        }
        return false
    }
}
