// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

package com.fluminaris.citusmail

import android.content.Context
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Runs one of the app's Dart entry points (in lib/main.dart) without a UI,
 * so background work uses the same Dart sync code as the app. Must be
 * called on the main thread.
 */
object BackgroundDart {
    const val CHANNEL = "fmail/background-task"

    /** Starts [entryPoint]; [onDone] runs when Dart calls "done" on [CHANNEL]. */
    fun start(context: Context, entryPoint: String, onDone: (Boolean) -> Unit): FlutterEngine {
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(context.applicationContext)
        loader.ensureInitializationComplete(context.applicationContext, null)
        // Plugins (keychain, folders, notifications) are registered as for the app.
        val engine = FlutterEngine(context.applicationContext)
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "done") {
                result.success(null)
                onDone(call.arguments as? Boolean ?: false)
            } else {
                result.notImplemented()
            }
        }
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(loader.findAppBundlePath(), entryPoint),
        )
        return engine
    }
}
