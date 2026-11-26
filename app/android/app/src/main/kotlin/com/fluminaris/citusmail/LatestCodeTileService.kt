// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

package com.fluminaris.citusmail

import android.content.ClipData
import android.content.ClipboardManager
import android.os.Build
import android.os.PersistableBundle
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.widget.Toast

/**
 * "Latest code" in Quick Settings: a tap copies the newest verification
 * code that is still fresh, without opening the app. The tile shows the
 * sender, never the code; on a locked phone it asks to unlock first. With
 * no fresh code it is inactive and says so.
 */
class LatestCodeTileService : TileService() {
    override fun onTileAdded() {
        LatestCode.setTileAdded(this, true)
        show()
    }

    override fun onTileRemoved() {
        LatestCode.setTileAdded(this, false)
    }

    override fun onStartListening() {
        // Also when the app's data was cleared while the tile stayed.
        if (!LatestCode.tileAdded(this)) LatestCode.setTileAdded(this, true)
        show()
    }

    override fun onClick() {
        if (isLocked) unlockAndRun { copy() } else copy()
    }

    private fun copy() {
        val value = LatestCode.read(this)
        if (value != null) {
            val clip = ClipData.newPlainText("Verification code", value.code)
            // Android 13+ hides it in its "copied" preview and confirms
            // the copy itself; before that, a short toast.
            clip.description.extras = PersistableBundle().apply {
                putBoolean(EXTRA_IS_SENSITIVE, true)
            }
            getSystemService(ClipboardManager::class.java)?.setPrimaryClip(clip)
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                Toast.makeText(this, "Code copied", Toast.LENGTH_SHORT).show()
            }
        }
        show()
    }

    private fun show() {
        val tile = qsTile ?: return
        val now = System.currentTimeMillis()
        val value = LatestCode.read(this, now)
        val name = getString(R.string.latest_code_tile)
        val text = when {
            value == null -> "No recent code"
            // The sender only once the phone is unlocked, as notifications.
            isSecure -> "Unlock to copy"
            else -> LatestCode.subtitle(value, now)
        }
        tile.state = if (value == null) Tile.STATE_INACTIVE else Tile.STATE_ACTIVE
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.label = name
            tile.subtitle = text
        } else {
            tile.label = if (value == null) name else text
        }
        tile.contentDescription = "$name: $text"
        tile.updateTile()
    }

    private companion object {
        const val EXTRA_IS_SENSITIVE = "android.content.extra.IS_SENSITIVE"
    }
}
