// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

package com.fluminaris.citusmail

import android.app.StatusBarManager
import android.content.ComponentName
import android.content.Context
import android.graphics.drawable.Icon
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.service.quicksettings.TileService
import android.util.Base64
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONObject

/**
 * The newest verification code, for the "Latest code" tile in Quick
 * Settings, which works with the app closed. Dart keeps it up to date
 * after each check for mail (lib/src/services/latest_code.dart).
 *
 * The value (sender, code, time) is encrypted with an AES key kept in the
 * Android Keystore, and kept only while the tile is added. A value past
 * its time is dropped when read.
 */
object LatestCode {
    const val CHANNEL = "citusmail/latest-code"

    data class Value(val sender: String, val code: String, val at: Long, val expires: Long) {
        fun isFresh(now: Long) = now < expires
    }

    private const val PREFS = "latest_code"
    private const val VALUE = "value"
    private const val TILE_ADDED = "tileAdded"
    private const val KEY_ALIAS = "citusmail.latestCode"

    /** Answers Dart on [CHANNEL]: "save", "clear", "requestTile". */
    fun register(messenger: BinaryMessenger, context: Context) {
        val app = context.applicationContext
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "save" -> {
                    val sender = call.argument<String>("sender")
                    val code = call.argument<String>("code")
                    val at = call.argument<Number>("at")?.toLong()
                    val expires = call.argument<Number>("expires")?.toLong()
                    if (sender == null || code == null || at == null || expires == null) {
                        result.error("bad-arguments", "sender, code, at, expires", null)
                    } else {
                        result.success(save(app, Value(sender, code, at, expires)))
                    }
                }
                "clear" -> {
                    clear(app)
                    result.success(null)
                }
                "requestTile" -> requestTile(context, result)
                else -> result.notImplemented()
            }
        }
    }

    /** Keeps [value] if the tile is added; false otherwise. */
    fun save(context: Context, value: Value): Boolean {
        if (!tileAdded(context)) return false
        val json = JSONObject()
            .put("sender", value.sender)
            .put("code", value.code)
            .put("at", value.at)
            .put("expires", value.expires)
        val sealed = try {
            encrypt(json.toString().toByteArray(Charsets.UTF_8))
        } catch (e: Exception) {
            return false
        }
        prefs(context).edit().putString(VALUE, sealed).apply()
        refreshTile(context)
        return true
    }

    /** The value, if there is one still fresh at [now]; drops it otherwise. */
    fun read(context: Context, now: Long = System.currentTimeMillis()): Value? {
        val sealed = prefs(context).getString(VALUE, null) ?: return null
        val value = try {
            val json = JSONObject(String(decrypt(sealed), Charsets.UTF_8))
            Value(
                json.getString("sender"),
                json.getString("code"),
                json.getLong("at"),
                json.getLong("expires"),
            )
        } catch (e: Exception) {
            null
        }
        if (value == null || !value.isFresh(now)) {
            prefs(context).edit().remove(VALUE).apply()
            return null
        }
        return value
    }

    fun clear(context: Context) {
        if (prefs(context).contains(VALUE)) {
            prefs(context).edit().remove(VALUE).apply()
            refreshTile(context)
        }
    }

    /** Whether the tile is in Quick Settings (only then is a code kept). */
    fun tileAdded(context: Context) = prefs(context).getBoolean(TILE_ADDED, false)

    fun setTileAdded(context: Context, added: Boolean) {
        val edit = prefs(context).edit().putBoolean(TILE_ADDED, added)
        if (!added) edit.remove(VALUE)
        edit.apply()
    }

    /** "Northwind Bank, 2 min ago". */
    fun subtitle(value: Value, now: Long): String {
        val minutes = ((now - value.at) / 60_000).coerceAtLeast(0)
        return if (minutes < 1) "${value.sender}, just now" else "${value.sender}, $minutes min ago"
    }

    // Android 13+: Android's own "Add tile" question. Before that, people
    // add it from the Quick Settings editor (Settings says how).
    private fun requestTile(context: Context, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success("unsupported")
            return
        }
        val statusBar = context.getSystemService(StatusBarManager::class.java)
        if (statusBar == null) {
            result.success("unsupported")
            return
        }
        try {
            statusBar.requestAddTileService(
                ComponentName(context, LatestCodeTileService::class.java),
                context.getString(R.string.latest_code_tile),
                Icon.createWithResource(context, R.drawable.ic_tile_code),
                context.mainExecutor,
            ) { answer ->
                result.success(
                    when (answer) {
                        StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED -> "added"
                        StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED -> "alreadyAdded"
                        StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_NOT_ADDED -> "notAdded"
                        else -> "unsupported"
                    },
                )
            }
        } catch (e: Exception) {
            result.success("unsupported")
        }
    }

    private fun refreshTile(context: Context) {
        try {
            TileService.requestListeningState(
                context,
                ComponentName(context, LatestCodeTileService::class.java),
            )
        } catch (e: Exception) {
            // The tile updates when Quick Settings next opens.
        }
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    // AES-GCM with a key that never leaves the Android Keystore. Stored as
    // base64 of the 12-byte IV followed by the ciphertext.
    private fun key(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    private fun encrypt(plain: ByteArray): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val sealed = cipher.iv + cipher.doFinal(plain)
        return Base64.encodeToString(sealed, Base64.NO_WRAP)
    }

    private fun decrypt(sealed: String): ByteArray {
        val bytes = Base64.decode(sealed, Base64.NO_WRAP)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes, 0, 12))
        return cipher.doFinal(bytes, 12, bytes.size - 12)
    }
}
