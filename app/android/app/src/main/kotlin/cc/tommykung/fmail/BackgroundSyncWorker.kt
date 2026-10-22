// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

package cc.tommykung.fmail

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.concurrent.futures.CallbackToFutureAdapter
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ListenableWorker
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.google.common.util.concurrent.ListenableFuture
import io.flutter.embedding.engine.FlutterEngine
import java.util.concurrent.TimeUnit

/**
 * Checks every account for new mail about every 15 minutes (the shortest
 * period Android allows), when there is a network. Android may wait longer
 * in battery saving.
 */
class BackgroundSyncWorker(context: Context, params: WorkerParameters) :
    ListenableWorker(context, params) {

    override fun startWork(): ListenableFuture<Result> =
        CallbackToFutureAdapter.getFuture { completer ->
            val main = Handler(Looper.getMainLooper())
            var engine: FlutterEngine? = null
            var finished = false
            fun finish(result: Result) {
                if (finished) return
                finished = true
                Log.i("Fmail", "background check finished: $result")
                main.post { engine?.destroy(); engine = null }
                completer.set(result)
            }
            main.post {
                engine = BackgroundDart.start(applicationContext, "backgroundSyncMain") { ok ->
                    finish(if (ok) Result.success() else Result.retry())
                }
            }
            // Never hold the device longer than this.
            main.postDelayed({ finish(Result.retry()) }, TimeUnit.MINUTES.toMillis(8))
            "fmail background sync"
        }

    companion object {
        private const val NAME = "fmail-periodic-sync"

        /** Schedules the periodic check (keeps an existing schedule). */
        fun schedule(context: Context) {
            val request = PeriodicWorkRequestBuilder<BackgroundSyncWorker>(15, TimeUnit.MINUTES)
                .setConstraints(
                    Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build(),
                )
                .build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                NAME,
                ExistingPeriodicWorkPolicy.KEEP,
                request,
            )
        }
    }
}
