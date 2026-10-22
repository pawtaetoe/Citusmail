# Release builds are shrunk by R8. Keep what is created by reflection.

# WorkManager (background checks) opens its Room database by reflection;
# without this, release builds crash at start with
# NoSuchMethodException: androidx.work.impl.WorkDatabase_Impl.<init>.
-keep class * extends androidx.room.RoomDatabase { <init>(); }

# Our classes started by Android from the manifest or by name.
-keep class cc.tommykung.fmail.InstantMailService { *; }
-keep class cc.tommykung.fmail.BackgroundSyncWorker { *; }
-keep class cc.tommykung.fmail.BootReceiver { *; }
