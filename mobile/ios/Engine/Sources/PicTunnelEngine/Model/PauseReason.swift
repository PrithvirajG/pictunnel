/// Why the whole run is paused. Mirrors the Pigeon `PauseReason` enum one to one.
public enum PauseReason: String, Codable, CaseIterable, Sendable {
    case user = "User"
    case wifiRequired = "WifiRequired"
    case chargingRequired = "ChargingRequired"
    case serverFull = "ServerFull"
    case quota = "Quota"
    case clientTooOld = "ClientTooOld"
    case permission = "Permission"
    /// The server's certificate no longer passes the pinning rule (P§6.3): pair again.
    case serverCertificateChanged = "ServerCertificateChanged"
}
