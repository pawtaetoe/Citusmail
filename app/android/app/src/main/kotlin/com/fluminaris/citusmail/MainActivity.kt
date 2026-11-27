// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

package com.fluminaris.citusmail

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ContentValues
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.PowerManager
import android.os.SystemClock
import android.provider.MediaStore
import android.provider.Settings
import androidx.core.content.FileProvider
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

// A FragmentActivity, as the system's fingerprint dialog (local_auth) needs.
class MainActivity : FlutterFragmentActivity() {
    private var oauth: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        oauth = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "citusmail/oauth")
        // The "Latest code" tile's value, and Android's "Add tile" question.
        LatestCode.register(flutterEngine.dartExecutor.binaryMessenger, this)
        // The periodic check (kept if already scheduled; does nothing until
        // an account exists).
        BackgroundSyncWorker.schedule(this)
        // Debug builds only, for testing: `adb shell am start ... --ez
        // citusmail.checkNow true` runs one background check at once (Android
        // delays forced periodic work); `--ez citusmail.instant true|false`
        // switches instant mail. Release builds are not debuggable and
        // ignore both.
        val debuggable = applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
        if (debuggable && intent.getBooleanExtra("citusmail.checkNow", false)) {
            WorkManager.getInstance(this)
                .enqueue(OneTimeWorkRequestBuilder<BackgroundSyncWorker>().build())
        }
        if (debuggable && intent.hasExtra("citusmail.instant")) {
            InstantMailService.setEnabled(this, intent.getBooleanExtra("citusmail.instant", false))
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "citusmail/background")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setInstant" -> {
                        InstantMailService.setEnabled(this, call.arguments as? Boolean ?: false)
                        result.success(null)
                    }
                    // A message scheduled with "Send later" is due then.
                    "checkAt" -> {
                        (call.arguments as? Number)?.let {
                            BackgroundSyncWorker.checkAt(this, it.toLong())
                        }
                        result.success(null)
                    }
                    // Whether Android holds background checks back to save
                    // battery (Settings shows a way to allow them).
                    "batteryOptimized" -> {
                        val power = getSystemService(PowerManager::class.java)
                        result.success(power?.isIgnoringBatteryOptimizations(packageName) == false)
                    }
                    // Android's own one-tap question: let the app run in the
                    // background without battery limits (Instant mail keeps
                    // its connection while the phone sleeps). Falls back to
                    // the app's settings page where the question is missing.
                    "askUnrestricted" -> {
                        val power = getSystemService(PowerManager::class.java)
                        if (power?.isIgnoringBatteryOptimizations(packageName) == false) {
                            try {
                                startActivity(
                                    Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                                        .setData(Uri.parse("package:$packageName")),
                                )
                            } catch (e: ActivityNotFoundException) {
                                startActivity(
                                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                                        .setData(Uri.fromParts("package", packageName, null)),
                                )
                            }
                        }
                        result.success(null)
                    }
                    // This app's page in Android's settings, where Battery
                    // can be set to Unrestricted. No special permission.
                    "openAppSettings" -> {
                        startActivity(
                            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                                .setData(Uri.fromParts("package", packageName, null)),
                        )
                        result.success(null)
                    }
                    // Time since the device started, which keeps counting
                    // while it sleeps and which nobody can set: the app
                    // lock measures its waits on it, so changing the date
                    // does not shorten them.
                    "elapsedRealtime" -> result.success(SystemClock.elapsedRealtime())
                    // App lock on: the app switcher shows no picture of the
                    // mail (Android 13+; older versions show the app's own
                    // cover).
                    "setPrivate" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            setRecentsScreenshotEnabled(!(call.arguments as? Boolean ?: false))
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "citusmail/files")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openCalendar" -> {
                        val name = call.argument<String>("name") ?: "event.ics"
                        val bytes = call.argument<ByteArray>("bytes")
                        result.success(bytes != null && openCalendar(name, bytes))
                    }
                    "shareFile" -> {
                        val name = call.argument<String>("name") ?: "file"
                        val bytes = call.argument<ByteArray>("bytes")
                        val title = call.argument<String>("title") ?: ""
                        result.success(bytes != null && shareFile(name, bytes, title))
                    }
                    "saveToDownloads" -> {
                        val name = call.argument<String>("name") ?: "file"
                        val bytes = call.argument<ByteArray>("bytes")
                        val mime = call.argument<String>("mime") ?: "application/octet-stream"
                        result.success(if (bytes == null) null else saveToDownloads(name, bytes, mime))
                    }
                    "forgetSharedFile" -> {
                        File(cacheDir, "pairing").deleteRecursively()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // A meeting invitation handed to the user's calendar app: the .ics
    // file goes to the app's cache (only the latest is kept) and is
    // offered through FileProvider to whichever app views text/calendar,
    // with read access to that one file only. False if no app took it.
    private fun openCalendar(name: String, bytes: ByteArray): Boolean {
        val directory = File(cacheDir, "events")
        directory.deleteRecursively()
        directory.mkdirs()
        val safeName = name.replace(Regex("""[/\\\x00-\x1f]"""), "_").ifBlank { "event.ics" }
        val file = File(directory, safeName)
        if (file.canonicalFile.parentFile != directory.canonicalFile) return false
        file.writeBytes(bytes)
        val uri = FileProvider.getUriForFile(this, "$packageName.files", file)
        val view = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "text/calendar")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        return try {
            startActivity(view)
            true
        } catch (e: ActivityNotFoundException) {
            false
        }
    }

    // A file the user saved, into the public Downloads/Citusmail folder
    // where the Files app and other apps find it (Android 10+: through
    // MediaStore, no storage permission needed). The system picks a free
    // name ("report (1).pdf"), so nothing is overwritten. Returns the name
    // it was saved under, or null on older Android (Dart then keeps it in
    // the app's own folder) or when it could not be written.
    private fun saveToDownloads(name: String, bytes: ByteArray, mime: String): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        val safeName = name.replace(Regex("""[/\\\x00-\x1f]"""), "_").ifBlank { "file" }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, safeName)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/Citusmail")
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val resolver = contentResolver
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: return null
        return try {
            resolver.openOutputStream(uri)?.use { it.write(bytes) } ?: throw IOException("no stream")
            resolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
            resolver.query(uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) it.getString(0) else null
            } ?: safeName
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            null
        }
    }

    // The sealed accounts file for "Send accounts to a computer", handed
    // to the app the user picks in the share sheet (Quick Share, a
    // messenger, USB...), with read access to that one file only. Only
    // the latest is kept; Dart asks to delete it once it can no longer be
    // opened anyway. False if nothing could take it.
    private fun shareFile(name: String, bytes: ByteArray, title: String): Boolean {
        val directory = File(cacheDir, "pairing")
        directory.deleteRecursively()
        directory.mkdirs()
        val safeName = name.replace(Regex("""[/\\\x00-\x1f]"""), "_").ifBlank { "file" }
        val file = File(directory, safeName)
        if (file.canonicalFile.parentFile != directory.canonicalFile) return false
        file.writeBytes(bytes)
        val uri = FileProvider.getUriForFile(this, "$packageName.files", file)
        val send = Intent(Intent.ACTION_SEND)
            .setType("application/octet-stream")
            .putExtra(Intent.EXTRA_STREAM, uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        send.clipData = ClipData.newRawUri(safeName, uri)
        return try {
            startActivity(Intent.createChooser(send, title))
            true
        } catch (e: ActivityNotFoundException) {
            false
        }
    }

    // The browser hands back the answer to a sign-in (singleTop: this same
    // activity). Dart checks it against the sign-in it started.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val data = intent.data ?: return
        if (data.scheme == "com.fluminaris.citusmail" && data.host == "oauth") {
            oauth?.invokeMethod("redirect", data.toString())
        }
    }
}
