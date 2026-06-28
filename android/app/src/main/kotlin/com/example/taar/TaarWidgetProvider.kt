package com.example.taar

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.BroadcastReceiver.PendingResult
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import android.widget.RemoteViews
import java.net.URL
import java.util.concurrent.Executors

class TaarWidgetProvider : AppWidgetProvider() {

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    /** Called when the first widget instance is added to the home screen. */
    override fun onEnabled(context: Context) {
        super.onEnabled(context)
        // Start the periodic AlarmManager poll so the widget stays live
        // even when the Flutter app is killed.
        WidgetUpdateService.scheduleNext(context)
    }

    /** Called when the last widget instance is removed from the home screen. */
    override fun onDisabled(context: Context) {
        super.onDisabled(context)
        WidgetUpdateService.cancelPolling(context)
    }

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val prefs     = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val title     = prefs.getString("widget_title",      "Nothing playing") ?: "Nothing playing"
        val artist    = prefs.getString("widget_artist",     "") ?: ""
        val imageUrl  = prefs.getString("widget_image",      "") ?: ""
        val isPlaying = prefs.getBoolean("widget_is_playing", false)
        val position  = prefs.getLong("widget_position_ms",  0L)
        val duration  = prefs.getLong("widget_duration_ms",  0L)
        val progress  = calcProgress(position, duration)

        for (id in ids) {
            manager.updateAppWidget(id, buildViews(context, title, artist, isPlaying, progress, null))
        }

        if (imageUrl.isNotEmpty()) {
            loadBitmapAsync(imageUrl) { bitmap ->
                val allIds = manager.getAppWidgetIds(
                    ComponentName(context, TaarWidgetProvider::class.java)
                )
                for (id in allIds) {
                    manager.updateAppWidget(id, buildViews(context, title, artist, isPlaying, progress, bitmap))
                }
            }
        }
    }

    // ── Broadcast receiver ────────────────────────────────────────────────────

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)

        when (intent.action) {

            // ── Widget button presses ─────────────────────────────────────────

            ACTION_PLAY_PAUSE -> {
                val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                val wasPlaying = prefs.getBoolean("widget_is_playing", false)
                prefs.edit().putBoolean("widget_is_playing", !wasPlaying).apply()
                sendMediaKey(context, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE)
                // Reschedule poll so progress resumes/pauses immediately
                WidgetUpdateService.scheduleNext(context)
                triggerUpdate(context)
            }

            ACTION_PREV -> {
                sendMediaKey(context, KeyEvent.KEYCODE_MEDIA_PREVIOUS)
                // Give AudioService time to update metadata, then sync + redraw.
                // goAsync() keeps the receiver alive across the delay + the
                // async MediaBrowser connection inside startSyncService().
                val pendingResult = goAsync()
                Handler(Looper.getMainLooper()).postDelayed({
                    startSyncService(context, pendingResult)
                }, 800)
            }

            ACTION_NEXT -> {
                sendMediaKey(context, KeyEvent.KEYCODE_MEDIA_NEXT)
                val pendingResult = goAsync()
                Handler(Looper.getMainLooper()).postDelayed({
                    startSyncService(context, pendingResult)
                }, 800)
            }

            // ── AlarmManager periodic poll ────────────────────────────────────
            // Fired by WidgetUpdateService.scheduleNext() every 15 seconds.
            // Syncs from MediaSession and redraws.

            "com.example.taar.WIDGET_POLL" -> {
                startSyncService(context, goAsync())
            }

            // ── just_audio_background / Android media broadcasts ───────────────
            // These fire when song or state changes from notification, BT,
            // lock screen, headphones etc. — even when Flutter app is killed.

            "com.ryanheise.audioservice.STATE_CHANGED",
            "android.media.PLAYBACK_STATE_CHANGED" -> {
                // State changed (play ↔ pause). Sync immediately.
                startSyncService(context, goAsync())
            }

            "com.ryanheise.audioservice.MEDIA_ITEM_CHANGED",
            "android.media.METADATA_CHANGED" -> {
                // New track. Give AudioService 500 ms to settle metadata.
                val pendingResult = goAsync()
                Handler(Looper.getMainLooper()).postDelayed({
                    startSyncService(context, pendingResult)
                }, 500)
            }
        }
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    /**
     * Sync MediaSession → prefs → widget (async — connects to AudioService),
     * then release [pendingResult] so the system knows this receiver is done.
     */
    private fun startSyncService(context: Context, pendingResult: PendingResult) {
        WidgetUpdateService.performSync(context) { pendingResult.finish() }
    }

    /** Force onUpdate to run now on every active widget instance. */
    private fun triggerUpdate(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        val ids = manager.getAppWidgetIds(ComponentName(context, TaarWidgetProvider::class.java))
        if (ids.isNotEmpty()) onUpdate(context, manager, ids)
    }

    /**
     * Sends a media key to just_audio_background's MediaButtonReceiver.
     * Controls playback without bringing the app to the foreground.
     */
    private fun sendMediaKey(context: Context, keyCode: Int) {
        val component = ComponentName(
            context.packageName,
            "com.ryanheise.audioservice.MediaButtonReceiver"
        )
        fun send(action: Int) = context.sendBroadcast(
            Intent(Intent.ACTION_MEDIA_BUTTON).apply {
                this.component = component
                putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(action, keyCode))
            }
        )
        send(KeyEvent.ACTION_DOWN)
        send(KeyEvent.ACTION_UP)
    }

    private fun buildViews(
        context: Context,
        title: String,
        artist: String,
        isPlaying: Boolean,
        progress: Int,
        albumArt: Bitmap?
    ): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.taar_widget)

        views.setTextViewText(R.id.widget_title,  title)
        views.setTextViewText(R.id.widget_artist, artist)

        views.setImageViewResource(
            R.id.widget_play_pause,
            if (isPlaying) R.drawable.ic_pause else R.drawable.ic_play
        )

        if (albumArt != null) {
            views.setImageViewBitmap(R.id.widget_album_art, albumArt)
        } else {
            views.setImageViewResource(R.id.widget_album_art, R.mipmap.ic_launcher)
        }

        views.setProgressBar(R.id.widget_progress, 100, progress, false)

        // Album art / title / artist → open app
        val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
        if (launchIntent != null) {
            val openApp = PendingIntent.getActivity(
                context, 0, launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.widget_album_art, openApp)
            views.setOnClickPendingIntent(R.id.widget_title,     openApp)
            views.setOnClickPendingIntent(R.id.widget_artist,    openApp)
        }

        views.setOnClickPendingIntent(R.id.widget_play_pause, widgetBroadcast(context, ACTION_PLAY_PAUSE, 1))
        views.setOnClickPendingIntent(R.id.widget_prev,       widgetBroadcast(context, ACTION_PREV,       2))
        views.setOnClickPendingIntent(R.id.widget_next,       widgetBroadcast(context, ACTION_NEXT,       3))

        return views
    }

    private fun widgetBroadcast(context: Context, action: String, requestCode: Int): PendingIntent =
        PendingIntent.getBroadcast(
            context, requestCode,
            Intent(context, TaarWidgetProvider::class.java).apply { this.action = action },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

    private fun calcProgress(positionMs: Long, durationMs: Long): Int =
        if (durationMs > 0L)
            ((positionMs.toFloat() / durationMs.toFloat()) * 100f).toInt().coerceIn(0, 100)
        else 0

    private fun loadBitmapAsync(url: String, onDone: (Bitmap?) -> Unit) {
        val executor = Executors.newSingleThreadExecutor()
        val handler  = Handler(Looper.getMainLooper())
        executor.execute {
            val bitmap = try {
                BitmapFactory.decodeStream(URL(url).openStream())
            } catch (e: Exception) { null }
            handler.post { onDone(bitmap) }
        }
    }

    companion object {
        const val ACTION_PLAY_PAUSE = "ACTION_PLAY_PAUSE"
        const val ACTION_PREV       = "ACTION_SKIP_PREV"
        const val ACTION_NEXT       = "ACTION_SKIP_NEXT"
        private const val PREFS     = "HomeWidgetPreferences"
    }
}