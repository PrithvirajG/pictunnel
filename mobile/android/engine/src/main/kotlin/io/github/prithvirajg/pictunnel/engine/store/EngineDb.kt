package io.github.prithvirajg.pictunnel.engine.store

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.TypeConverter
import androidx.room.TypeConverters
import io.github.prithvirajg.pictunnel.engine.model.ItemState

/** Item states are stored by name, so renaming a constant is a schema change. */
class Converters {
    @TypeConverter
    fun stateToString(s: ItemState): String = s.name

    @TypeConverter
    fun stringToState(s: String): ItemState = ItemState.valueOf(s)
}

@Database(
    entities = [
        ItemEntity::class,
        HashCacheEntity::class,
        ScanStateEntity::class,
        ActivityEntity::class,
        SettingEntity::class,
    ],
    version = 1,
    exportSchema = true,
)
@TypeConverters(Converters::class)
abstract class EngineDb : RoomDatabase() {
    abstract fun items(): ItemsDao

    abstract fun hashCache(): HashCacheDao

    abstract fun scanState(): ScanStateDao

    abstract fun activity(): ActivityDao

    abstract fun settings(): SettingsDao

    companion object {
        const val FILE_NAME = "pictunnel-engine.db"

        /** The on-device database, in app storage only (R3: lost on reinstall). */
        fun open(context: Context): EngineDb =
            Room.databaseBuilder(context.applicationContext, EngineDb::class.java, FILE_NAME).build()
    }
}
