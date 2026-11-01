// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

package com.fluminaris.citusmail

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.concurrent.futures.CallbackToFutureAdapter
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.ListenableWorker
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.google.common.util.concurrent.ListenableFuture
import io.flutter.embedding.engine.FlutterEngine
import java.util.concurrent.TimeUnit

/**
 * Checks every account for new mail about every 5 minutes, when there is a
 * network. Android's periodic work runs at most every 15 minutes, so each
 * check schedules the next one 5 minutes later; the 15-minute periodic
 * work stays as a safety net that restarts this chain if Android drops it.
 * Android may wait longer in battery saving (Doze).
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
                Log.i("Citusmail", "background check finished: $result")
                // A chained check appends the next one (replacing would cancel
                // this very check); the periodic one only restarts a chain
                // that is gone.
                scheduleNext(
                    applicationContext,
                    if (tags.contains(CHAIN_TAG)) {
                        ExistingWorkPolicy.APPEND_OR_REPLACE
                    } else {
                        ExistingWorkPolicy.KEEP
                    },
                )
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
            "citusmail background sync"
        }

    companion object {
        private const val NAME = "citusmail-periodic-sync"

        /** The schedule's name before the app was renamed from Fmail. */
        private const val OLD_NAME = "fmail-periodic-sync"

        /** The next check of the 5-minute chain. */
        private const val NEXT_NAME = "citusmail-next-check"

        /** Marks the checks of the chain (not the periodic safety net). */
        private const val CHAIN_TAG = "citusmail-chain"

        /** Time between checks. */
        private const val MINUTES = 5L

        private val network =
            Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()

        /**
         * Schedules the next check in [MINUTES]. KEEP leaves a pending one in
         * place; APPEND_OR_REPLACE queues it after the running check.
         */
        private fun scheduleNext(context: Context, policy: ExistingWorkPolicy) {
            val request = OneTimeWorkRequestBuilder<BackgroundSyncWorker>()
                .setInitialDelay(MINUTES, TimeUnit.MINUTES)
                .setConstraints(network)
                .addTag(CHAIN_TAG)
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork(NEXT_NAME, policy, request)
        }

        /** Schedules the checks (keeps existing schedules). */
        fun schedule(context: Context) {
            scheduleNext(context, ExistingWorkPolicy.KEEP)
            val request = PeriodicWorkRequestBuilder<BackgroundSyncWorker>(15, TimeUnit.MINUTES)
                .setConstraints(network)
                .build()
            val work = WorkManager.getInstance(context)
            // One schedule only: drop the one made under the old name.
            work.cancelUniqueWork(OLD_NAME)
            work.enqueueUniquePeriodicWork(
                NAME,
                ExistingPeriodicWorkPolicy.KEEP,
                request,
            )
        }
    }
}
