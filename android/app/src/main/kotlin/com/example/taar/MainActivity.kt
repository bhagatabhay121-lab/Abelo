package com.example.taar

import android.app.KeyguardManager
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.WindowManager
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {

    private val METHOD_CHANNEL = "com.example.taar/lock_screen"
    private val EVENT_CHANNEL  = "com.example.taar/lock_screen_events"

    private var eventSink: EventChannel.EventSink? = null

    // Listens for screen on/off and user-unlock broadcasts
    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                Intent.ACTION_SCREEN_ON  -> eventSink?.success(true)   // screen woke, still locked
                Intent.ACTION_SCREEN_OFF -> eventSink?.success(true)   // screen went off, locked
                Intent.ACTION_USER_PRESENT -> eventSink?.success(false) // user unlocked
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        applyLockScreenFlags()
        applyEdgeToEdge()
        dismissWakeNotification()
    }

    override fun onResume() {
        super.onResume()
        // Re-apply on every resume — flags can be cleared by the system
        applyLockScreenFlags()
        // Tell Flutter the current lock state immediately on resume
        eventSink?.success(isKeyguardLocked())
        // We're visible now — the helper notification that woke us up is no
        // longer needed.
        dismissWakeNotification()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ── MethodChannel: on-demand "isLocked?" query from Flutter ───────
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            METHOD_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isLocked" -> result.success(isKeyguardLocked())
                "setPlaybackActive" -> {
                    TaarApplication.isPlaybackActive = call.argument<Boolean>("active") ?: false
                    result.success(null)
                }
                "canUseFullScreenIntent" -> result.success(canUseFullScreenIntent())
                "requestFullScreenIntentPermission" -> {
                    requestFullScreenIntentPermission()
                    result.success(null)
                }
                else       -> result.notImplemented()
            }
        }

        // ── EventChannel: push lock/unlock events to Flutter in real-time ─
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            EVENT_CHANNEL
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                eventSink = sink
                registerScreenReceiver()
                // Emit current state immediately so Flutter knows on startup
                sink.success(isKeyguardLocked())
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
                unregisterScreenReceiver()
            }
        })
    }

    // ── Helpers ───────────────────────────────────────────────────────────

    private fun applyLockScreenFlags() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            // API 27+ — non-deprecated preferred API
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            // API 21–26 — deprecated but functional fallback
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
            )
        }
    }

    private fun applyEdgeToEdge() {
        // Makes Flutter fill the full screen including status bar area,
        // so the lock screen overlay looks truly full-screen.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(false)
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = (
                android.view.View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
                android.view.View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                android.view.View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
            )
        }
    }

    private fun isKeyguardLocked(): Boolean {
        val km = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        return km.isKeyguardLocked
    }

    private fun dismissWakeNotification() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(TaarApplication.WAKE_NOTIFICATION_ID)
    }

    /**
     * On Android 14+ (API 34), USE_FULL_SCREEN_INTENT alone is not enough —
     * the user must explicitly flip it on for apps that aren't a default
     * dialer/alarm app. Below API 34 it's granted automatically at install.
     */
    private fun canUseFullScreenIntent(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            return nm.canUseFullScreenIntent()
        }
        return true
    }

    /**
     * Sends the user to the system settings screen where they can grant the
     * "Full screen notifications" special permission. There is no in-app
     * runtime prompt for this on Android 14+ — Settings is the only path.
     */
    private fun requestFullScreenIntentPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val intent = Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT).apply {
                data = Uri.fromParts("package", packageName, null)
            }
            startActivity(intent)
        }
    }

    private fun registerScreenReceiver() {
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_USER_PRESENT)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(screenReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(screenReceiver, filter)
        }
    }

    private fun unregisterScreenReceiver() {
        try { unregisterReceiver(screenReceiver) }
        catch (_: IllegalArgumentException) { /* already unregistered */ }
    }

    override fun onDestroy() {
        unregisterScreenReceiver()
        super.onDestroy()
    }
}
