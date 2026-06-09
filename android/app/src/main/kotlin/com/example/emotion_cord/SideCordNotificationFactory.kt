package com.example.emotion_cord

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.graphics.Color
import android.os.Build
import android.widget.RemoteViews
import androidx.core.app.NotificationCompat

object SideCordNotificationFactory {
    const val CHANNEL_ID = "overlay_service"
    const val NOTIFICATION_ID = 1102

    private const val CHANNEL_NAME = "Overlay Service"
    private const val TITLE = "SideCord Activated"
    private const val ADD_LABEL = "이모티콘 추가"
    private const val SEND_LABEL = "전송"

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return

        val channel = NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            NotificationManager.IMPORTANCE_LOW
        )
        channel.setShowBadge(false)
        manager.createNotificationChannel(channel)
    }

    fun build(
        context: Context,
        addIntent: PendingIntent,
        sendIntent: PendingIntent,
        deleteIntent: PendingIntent? = null
    ): Notification {
        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(TITLE)
            .setContentText(TITLE)
            .setTicker(TITLE)
            .setContentIntent(sendIntent)
            .setCustomContentView(createContentView(context, sendIntent))
            .setCustomBigContentView(createContentView(context, sendIntent))
            .setStyle(NotificationCompat.DecoratedCustomViewStyle())
            .setColor(Color.rgb(47, 128, 237))
            .setColorized(false)
            .addAction(android.R.drawable.ic_input_add, ADD_LABEL, addIntent)
            .setOngoing(false)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
        if (deleteIntent != null) {
            builder.setDeleteIntent(deleteIntent)
        }
        return builder.build()
    }

    private fun createContentView(
        context: Context,
        sendIntent: PendingIntent
    ): RemoteViews {
        return RemoteViews(context.packageName, R.layout.sidecord_notification).apply {
            setTextViewText(R.id.sidecord_notification_title, TITLE)
            setTextViewText(R.id.sidecord_notification_send, SEND_LABEL)
            setOnClickPendingIntent(R.id.sidecord_notification_send, sendIntent)
            setOnClickPendingIntent(R.id.sidecord_notification_root, sendIntent)
        }
    }
}
