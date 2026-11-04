// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

package com.fluminaris.citusmail.background_clipboard

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.PersistableBundle
import android.widget.Toast
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Writes text to the clipboard with the application context, so it works in
 * any Flutter engine: also the headless one started for a notification
 * button, where Flutter's own Clipboard has no handler (it needs a window).
 *
 * Writing to the clipboard is allowed from the background on every Android
 * version; only reading it is restricted (Android 10+), and this never reads.
 */
class BackgroundClipboardPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var context: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "copy") {
            result.notImplemented()
            return
        }
        val context = this.context
        val text = call.argument<String>("text")
        if (context == null || text == null) {
            result.error("unavailable", "No context or no text", null)
            return
        }
        val clipboard = context.getSystemService(ClipboardManager::class.java)
        if (clipboard == null) {
            result.error("unavailable", "No clipboard", null)
            return
        }
        val clip = ClipData.newPlainText(call.argument<String>("label") ?: "", text)
        if (call.argument<Boolean>("sensitive") == true) {
            // Android 13+ hides sensitive text in its "copied" preview and
            // keyboard suggestions (ClipDescription.EXTRA_IS_SENSITIVE).
            clip.description.extras = PersistableBundle().apply {
                putBoolean(EXTRA_IS_SENSITIVE, true)
            }
        }
        clipboard.setPrimaryClip(clip)
        // Android 13+ confirms a copy itself; before that, a short toast.
        val confirmation = call.argument<String>("confirmation")
        if (confirmation != null && Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            Toast.makeText(context, confirmation, Toast.LENGTH_SHORT).show()
        }
        result.success(true)
    }

    private companion object {
        const val CHANNEL = "citusmail/background-clipboard"
        const val EXTRA_IS_SENSITIVE = "android.content.extra.IS_SENSITIVE"
    }
}
