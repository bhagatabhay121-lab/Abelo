package com.example.taar

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.support.v4.media.MediaBrowserCompat
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaControllerCompat
import android.support.v4.media.session.PlaybackStateCompat

/**
 * Syncs the just_audio_background MediaSession (title, artist, position,
 * duration, isPlaying) into HomeWidgetPreferences and redraws the widget.
 *
 * IMPORTANT: this connects directly to OUR OWN app's AudioService via
 * MediaBrowserCompat. This is the correct approach — and it replaces an
 * earlier broken version that tried MediaSessionManager.getActiveSessions(),
 * which requires either the MEDIA_CONTENT_CONTROL permission (signature
 * |privileged — a normal app can never be granted it) or a user-approved
 * NotificationListenerService (which this app doesn't have). That call was
 * always throwing SecurityException and silently falling back to stale
 * prefs, so the widget never actually picked up live data.
 *
 * Binding to a service (what MediaBrowserCompat does under the hood) is, 
 * unlike starting one, allowed even while the app is in the background —
 * so this also avoids the IllegalStateException ("app is in background")
 * crash that the old context.startService() approach hit.
 *
 * This is a plain object, not an Android Service.
 */
object WidgetUpdateService {

    private const val POLL_INTERVAL_MS = 15_000L
    private const val ACTION_POLL = "com.example.taar.WIDGET_POLL"
    private const val CONNECT_TIMEOUT_MS = 3_000L
    private const val PREFS = "HomeWidgetPreferences"

    /**
     * Read MediaSession → write prefs → redraw widget, then reschedule the
     * next poll. [onComplete] always runs exactly once. Pass it the
     * BroadcastReceiver's PendingResult.finish() so the receiver doesn't
     * get torn down before this async work is done.
     */
    fun performSync(context: Context, onComplete: () -> Unit = {}) {
        scheduleNext(context)
        connectAndSync(context, onComplete)
    }

    // ── Connect to our own AudioService session and read it ──────────────────

    private fun connectAndSync(context: Context, onComplete: () -> Unit) {
        val mainHandler = Handler(Looper.getMainLooper())
        var finished = false
        var browser: MediaBrowserCompat? = null

        fun finishOnce() {
            if (finished) return
            finished = true
            try { browser?.disconnect() } catch (e: Exception) { /* no-op */ }
            triggerWidgetUpdate(context)
            onComplete()
        }

        try {
            browser = MediaBrowserCompat(
                context,
                ComponentName(context, com.ryanheise.audioservice.AudioService::class.java),
                object : MediaBrowserCompat.ConnectionCallback() {
                    override fun onConnected() {
                        try {
                            val token = browser?.sessionToken
                            if (token != null) {
                                writeMetadataToPrefs(context, MediaControllerCompat(context, token))
                            }
                        } catch (e: Exception) {
                            // Fall through — redraw with whatever prefs already hold
                        } finally {
                            finishOnce()
                        }
                    }

                    override fun onConnectionSuspended() = finishOnce()
                    override fun onConnectionFailed() = finishOnce()
                },
                null
            )
            browser.connect()
            // Safety net in case the service never calls back (e.g. it crashed)
            mainHandler.postDelayed({ finishOnce() }, CONNECT_TIMEOUT_MS)
        } catch (e: Exception) {
            finishOnce()
        }
    }

    private fun writeMetadataToPrefs(context: Context, controller: MediaControllerCompat) {
        val metadata   = controller.metadata
        val pbState    = controller.playbackState
        val isPlaying  = pbState?.state == PlaybackStateCompat.STATE_PLAYING
        val positionMs = pbState?.position ?: 0L
        val durationMs = metadata?.getLong(MediaMetadataCompat.METADATA_KEY_DURATION) ?: 0L
        val title      = metadata?.getString(MediaMetadataCompat.METADATA_KEY_TITLE) ?: ""
        val artist     = metadata?.getString(MediaMetadataCompat.METADATA_KEY_ARTIST) ?: ""

        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs.edit().apply {
            if (title.isNotEmpty())  putString("widget_title", title)
            if (artist.isNotEmpty()) putString("widget_artist", artist)
            putBoolean("widget_is_playing", isPlaying)
            putLong("widget_position_ms", positionMs)
            putLong("widget_duration_ms", durationMs)
            apply()
        }
    }

    // ── AlarmManager polling helpers ──────────────────────────────────────────

    /** Call this once (e.g. from TaarWidgetProvider.onEnabled) to start polling. */
    fun scheduleNext(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.set(
            AlarmManager.ELAPSED_REALTIME,
            SystemClock.elapsedRealtime() + POLL_INTERVAL_MS,
            pollIntent(context)
        )
    }

    /** Cancel polling (call from TaarWidgetProvider.onDisabled). */
    fun cancelPolling(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.cancel(pollIntent(context))
    }

    private fun pollIntent(context: Context): PendingIntent =
        PendingIntent.getBroadcast(
            context, 99,
            Intent(context, TaarWidgetProvider::class.java).apply {
                action = ACTION_POLL
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

    fun triggerWidgetUpdate(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        val ids = manager.getAppWidgetIds(
            ComponentName(context, TaarWidgetProvider::class.java)
        )
        if (ids.isNotEmpty()) {
            val intent = Intent(context, TaarWidgetProvider::class.java).apply {
                action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
                putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
            }
            context.sendBroadcast(intent)
        }
    }
}