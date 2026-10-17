package io.github.prithvirajg.pictunnel.engine.model

/** Values of the item `kind` column (M§4.1). */
object ItemKind {
    const val PHOTO = "photo"
    const val VIDEO = "video"
    const val LIVE_PHOTO = "live_photo"
}

/** Values of the item `pairRole` column and of the tus `pair_role` metadata (H4). */
object PairRole {
    const val PRIMARY = "primary"
    const val LIVE_VIDEO = "live_video"
}

/** R5: retryable failures an item may accumulate before it needs attention. */
const val MAX_ATTEMPTS = 10
