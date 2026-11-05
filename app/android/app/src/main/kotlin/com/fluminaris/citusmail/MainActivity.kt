// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

package com.fluminaris.citusmail

import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.content.FileProvider
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

// A FragmentActivity, as the system's fingerprint dialog (local_auth) needs.
class MainActivity : FlutterFragmentActivity() {
    private var oauth: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        oauth = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "citusmail/oauth")
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
                    // This app's page in Android's settings, where Battery
                    // can be set to Unrestricted. No special permission.
                    "openAppSettings" -> {
                        startActivity(
                            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                                .setData(Uri.fromParts("package", packageName, null)),
                        )
                        result.success(null)
                    }
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
