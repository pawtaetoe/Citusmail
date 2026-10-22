// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

package com.fluminaris.citusmail

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** After a restart: instant mail comes back if it was on (the periodic check
 * is kept by WorkManager itself). */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        if (InstantMailService.isEnabled(context)) {
            runCatching { InstantMailService.setEnabled(context, true) }
        }
    }
}
