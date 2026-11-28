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
 *
 * Every engine has its own mail connections, and the account's server
 * allows only a few (Gmail about 15, shared by all devices). So while the
 * app's own engine syncs ([appSyncing], set by the app), the background
 * engines leave the mail to it: the periodic check asks the app to check
 * ("checkElsewhere") instead of connecting itself, and Instant mail
 * pauses until the app's engine is gone. Without the app, the periodic
 * check asks Instant mail's engine, if it runs. All engines run in this
 * one process.
 */
object BackgroundDart {
    const val CHANNEL = "citusmail/background-task"

    /** Instant mail's entry point in lib/main.dart. */
    const val INSTANT_ENTRY_POINT = "instantMailMain"

    /** Whether the app's own engine is syncing mail; main thread only. */
    var appSyncing = false
        private set

    /** The app engine's "citusmail/background" channel, while it runs. */
    private var app: MethodChannel? = null

    /** The channel of each background engine running. */
    private val channels = mutableMapOf<FlutterEngine, MethodChannel>()

    /** Instant mail's engine, while it runs. */
    private var instant: FlutterEngine? = null

    /**
     * The app's engine started syncing (with [channel] to ask it for a
     * check) or stopped; tells every background engine.
     */
    fun setAppSyncing(on: Boolean, channel: MethodChannel? = null) {
        app = if (on) channel ?: app else null
        if (appSyncing == on) return
        appSyncing = on
        for (other in channels.values.toList()) other.invokeMethod("appSyncing", on)
    }

    /** Stops [engine] (started with [start]). */
    fun destroy(engine: FlutterEngine) {
        channels.remove(engine)
        if (instant == engine) instant = null
        engine.destroy()
    }

    /** Starts [entryPoint]; [onDone] runs when Dart calls "done" on [CHANNEL]. */
    fun start(context: Context, entryPoint: String, onDone: (Boolean) -> Unit): FlutterEngine {
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(context.applicationContext)
        loader.ensureInitializationComplete(context.applicationContext, null)
        // Plugins (keychain, folders, notifications) are registered as for the app.
        val engine = FlutterEngine(context.applicationContext)
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channels[engine] = channel
        if (entryPoint == INSTANT_ENTRY_POINT) instant = engine
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "done" -> {
                    result.success(null)
                    onDone(call.arguments as? Boolean ?: false)
                }
                "appSyncing" -> result.success(appSyncing)
                // The app's engine (else Instant mail's) checks the mail
                // instead: true or false when it did (whether all went
                // well), null when none runs (or Instant mail is paused),
                // so the periodic check does it itself.
                "checkElsewhere" -> {
                    val target = if (appSyncing) app else instant?.takeIf { it != engine }?.let { channels[it] }
                    if (target == null) {
                        result.success(null)
                    } else {
                        target.invokeMethod(
                            "checkNow",
                            null,
                            object : MethodChannel.Result {
                                override fun success(value: Any?) {
                                    result.success(value as? Boolean)
                                }

                                override fun error(code: String, message: String?, details: Any?) {
                                    result.success(null)
                                }

                                override fun notImplemented() {
                                    result.success(null)
                                }
                            },
                        )
                    }
                }
                // The next scheduled message's time ("Send later").
                "checkAt" -> {
                    (call.arguments as? Number)?.let {
                        BackgroundSyncWorker.checkAt(
                            context.applicationContext,
                            it.toLong(),
                            fromCheck = true,
                        )
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        // Each check keeps the "Latest code" tile's value up to date.
        LatestCode.register(engine.dartExecutor.binaryMessenger, context)
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(loader.findAppBundlePath(), entryPoint),
        )
        return engine
    }
}
