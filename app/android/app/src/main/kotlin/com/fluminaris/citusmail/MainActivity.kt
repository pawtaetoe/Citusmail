// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

package com.fluminaris.citusmail

import android.content.pm.ApplicationInfo
import android.os.Build
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// A FragmentActivity, as the system's fingerprint dialog (local_auth) needs.
class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The periodic check (kept if already scheduled; does nothing until
        // an account exists).
        BackgroundSyncWorker.schedule(this)
        // Debug builds only, for testing: `adb shell am start ... --ez
        // fmail.checkNow true` runs one background check at once (Android
        // delays forced periodic work); `--ez fmail.instant true|false`
        // switches instant mail. Release builds are not debuggable and
        // ignore both.
        val debuggable = applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
        if (debuggable && intent.getBooleanExtra("fmail.checkNow", false)) {
            WorkManager.getInstance(this)
                .enqueue(OneTimeWorkRequestBuilder<BackgroundSyncWorker>().build())
        }
        if (debuggable && intent.hasExtra("fmail.instant")) {
            InstantMailService.setEnabled(this, intent.getBooleanExtra("fmail.instant", false))
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "fmail/background")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setInstant" -> {
                        InstantMailService.setEnabled(this, call.arguments as? Boolean ?: false)
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
    }
}
