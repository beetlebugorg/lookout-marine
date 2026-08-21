package org.beetlebug.lookout

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Holds the process up while the boat's instruments are feeding.
 *
 * A chartplotter has to warn of a pending collision whether or not the mariner
 * is looking at it, and an app that is merely backgrounded has no right to keep
 * running: Android throttles it, freezes it, and reclaims it under pressure.
 * The engine, its plugins and the TCP session to the gateway are what would be
 * lost, so this declares them.
 *
 * The type is `connectedDevice`, and it is accurate rather than convenient: the
 * app holds a network session to an external device (the boat's instrument
 * gateway) and reads NMEA off it. That type is not time-limited. `dataSync`
 * would have been the obvious choice and is the wrong one, being capped at six
 * hours in any twenty-four from Android 15, which on a long passage means the
 * alarms stop somewhere off the coast. `location` will become true as well when
 * the app reads the device's own GPS; today the position arrives over the same
 * TCP session, so declaring it would claim something the app does not do.
 *
 * `connectedDevice` also carries a runtime prerequisite: the app must hold one
 * of a short list of permissions, and for a network-attached device that is
 * CHANGE_NETWORK_STATE. See the manifest.
 *
 * WHEN it runs is the whole of the design. The trigger is a live connection,
 * not a pending alarm: the thing that detects a collision is the thing that
 * would otherwise not be running, so an alarm-triggered service could never
 * raise its first alarm. It stops once nothing is connected, so a plotter
 * sitting at the dock holds no notification. See ChartController.updateService.
 */
class ChartService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Before anything else, including the guard below: a service started
        // into the foreground has a few seconds to say so or the system kills
        // the process for it.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification())
        }
        // Nothing to hold up. Reachable when the system restarts the service on
        // its own after the process died, which leaves no engine behind it.
        if (ChartEngine.get().lookout == null) {
            Log.i(TAG, "no engine to hold up; stopping")
            stopSelf()
        }
        // Never restarted by the system: what this protects is the state in
        // THIS process, and a restart would raise a notification with nothing
        // behind it.
        return START_NOT_STICKY
    }

    /**
     * What the mariner sees while it runs. It says what the app is doing, which
     * is receiving from the gateway and watching what arrives; tapping it comes
     * back to the chart.
     */
    private fun notification(): Notification {
        val open = Intent(this, LookoutActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            // Come back to the chart that is already there rather than building
            // a second copy of it over the first.
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        var pf = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) pf = pf or PendingIntent.FLAG_IMMUTABLE
        val tap = PendingIntent.getActivity(this, 0, open, pf)

        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            channel()
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return b
            .setContentTitle(getString(R.string.app_name))
            .setContentText(getString(R.string.service_running))
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(tap)
            .setOngoing(true)
            .build()
    }

    /** Low importance: it is a statement of fact, not something to answer. */
    private fun channel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(NotificationManager::class.java) ?: return
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        val c = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.service_channel),
            NotificationManager.IMPORTANCE_LOW,
        )
        c.setShowBadge(false)
        nm.createNotificationChannel(c)
    }

    companion object {
        private const val TAG = "lookout"
        private const val CHANNEL_ID = "instruments"
        private const val NOTIFICATION_ID = 1

        /**
         * Ask for the process to be held up. Only reliable from the foreground:
         * from Android 12 a background start throws, and there is no exemption
         * that fits. In practice the connection comes up while the mariner is
         * looking at the chart, which is the case that matters, and the sample
         * that would have started it from the background will try again the
         * next time they are.
         */
        /** True when the platform took the start. API 31+ refuses a foreground
         *  start from the background; the caller keeps its state honest and
         *  tries again later rather than believing the service is up. */
        fun start(ctx: Context): Boolean {
            val i = Intent(ctx, ChartService::class.java)
            return try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) ctx.startForegroundService(i)
                else ctx.startService(i)
                true
            } catch (e: Exception) {
                Log.w(TAG, "foreground service refused: $e")
                false
            }
        }

        fun stop(ctx: Context) {
            try {
                ctx.stopService(Intent(ctx, ChartService::class.java))
            } catch (e: Exception) {
                Log.w(TAG, "foreground service would not stop: $e")
            }
        }
    }
}
