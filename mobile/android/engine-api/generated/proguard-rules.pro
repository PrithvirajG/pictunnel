-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.AnnotationsKt # core serialization annotations

# kotlinx-serialization-json specific. Add this if you have java.lang.NoClassDefFoundError kotlinx.serialization.json.JsonObjectSerializer
-keepclassmembers class kotlinx.serialization.json.** { *** Companion; }
-keepclasseswithmembers class kotlinx.serialization.json.** { kotlinx.serialization.KSerializer serializer(...); }

# project specific.
-keep,includedescriptorclasses class io.github.prithvirajg.pictunnel.engineapi.models.**$$serializer { *; }
-keepclassmembers class io.github.prithvirajg.pictunnel.engineapi.models.** { *** Companion; }
-keepclasseswithmembers class io.github.prithvirajg.pictunnel.engineapi.models.** { kotlinx.serialization.KSerializer serializer(...); }
