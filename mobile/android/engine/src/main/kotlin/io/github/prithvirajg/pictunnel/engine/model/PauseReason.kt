package io.github.prithvirajg.pictunnel.engine.model

/** Why the whole run is paused. Mirrors the Pigeon `PauseReason` enum one to one. */
enum class PauseReason {
    User,
    WifiRequired,
    ChargingRequired,
    ServerFull,
    Quota,
    ClientTooOld,
    Permission,
}
