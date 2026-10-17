package io.github.prithvirajg.pictunnel.engine.model

/**
 * Item states, exactly the vector `item_state` enum (M§4.1). Stored by [name],
 * so the constants must never be renamed.
 */
enum class ItemState {
    Discovered,
    Hashed,
    Queued,
    Uploading,
    Verifying,
    BackedUp,
    Skipped,
    Freed,
    NeedsAttention,
    Paused,
    ;

    companion object {
        /** Parses a vector/protocol state name; null for blank or unknown names. */
        fun parse(name: String?): ItemState? = entries.firstOrNull { it.name == name }
    }
}
