package com.example.taar

import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import io.flutter.app.FlutterApplication

/**
 * Custom Application class.
 *
 * WHY THIS EXISTS:
 * The old approach registered the ACTION_SCREEN_ON receiver inside
 * MainActivity, tied to the EventChannel's onListen/onCancel. That meant the
 * receiver died the moment the Activity was destroyed (app swiped from
 * recents, OEM battery killer, etc.) — even though the foreground audio
 * service kept the process (and the music) alive. Result: the screen-on
 * broadcast had nobody listening, so the custom lock screen player never
 * appeared — only the default media notification did.
 *
 * Registering here, in Application.onCreate(), ties the receiver's lifetime
 * to the *process*, which is exactly as long as the foreground service is
 * alive. It is intentionally never unregistered.
 */
class TaarApplication : FlutterApplication() {

    companion object {
        // Set from Flutter (via MethodChannel) every time play/pause changes.
        @Volatile
        var isPlaybackActive: Boolean = false

        const val WAKE_CHANNEL_ID = "taar_lockscreen_wake"
        const val WAKE_NOTIFICATION_ID = 9911
    }

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != Intent.ACTION_SCREEN_ON) return
            if (!isPlaybackActive) return

            val km = context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
            if (!km.isKeyguardLocked) return // not actually locked, nothing to do

            launchOverLockScreen(context)
        }
    }

    override fun onCreate() {
        super.onCreate()
        val filter = IntentFilter(Intent.ACTION_SCREEN_ON)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(screenReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(screenReceiver, filter)
        }
    }

    /**
     * The OS-sanctioned way to launch an Activity over the keyguard from a
     * background process: a high-priority notification with a full-screen
     * intent attached. This is the same mechanism alarm clock and calling
     * apps use. Requires USE_FULL_SCREEN_INTENT in the manifest, and on
     * Android 14+ the user must additionally grant it in Settings (see
     * MainActivity.requestFullScreenIntentPermission).
     */
    private fun launchOverLockScreen(context: Context) {
        val activityIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            action = ACTION_SHOW_LOCK_PLAYER
        }
        val pendingIntent = PendingIntent.getActivity(
            context,
            0,
            activityIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                WAKE_CHANNEL_ID,
                "Lock screen player",
                NotificationManager.IMPORTANCE_HIGH
            ).apply { setSound(null, null) }
            nm.createNotificationChannel(channel)
        }

        val notification = Notification.Builder(context, WAKE_CHANNEL_ID)
            .setContentTitle(" ")
            .setSmallIcon(context.applicationInfo.icon)
            .setPriority(Notification.PRIORITY_MAX)
            .setCategory(Notification.CATEGORY_CALL) // treated as urgent/interruptive
            .setFullScreenIntent(pendingIntent, true)
            .setAutoCancel(true)
            .build()

        nm.notify(WAKE_NOTIFICATION_ID, notification)
    }
}

const val ACTION_SHOW_LOCK_PLAYER = "com.example.taar.ACTION_SHOW_LOCK_PLAYER"
