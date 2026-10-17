/// Item states, exactly the vector `item_state` enum (M§4.1). Stored by raw value, so the raw
/// values must never change.
public enum ItemState: String, Codable, CaseIterable, Sendable {
    case discovered = "Discovered"
    case hashed = "Hashed"
    case queued = "Queued"
    case uploading = "Uploading"
    case verifying = "Verifying"
    case backedUp = "BackedUp"
    case skipped = "Skipped"
    case freed = "Freed"
    case needsAttention = "NeedsAttention"
    case paused = "Paused"
}
