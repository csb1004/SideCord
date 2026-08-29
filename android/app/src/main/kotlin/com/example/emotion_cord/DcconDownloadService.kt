package com.example.emotion_cord

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

class DcconDownloadService : Service() {
    companion object {
        const val EXTRA_DATA = "data"
        const val PREF_ACTIVE = "flutter.dccon_download_active"
        const val PREF_COMPLETED_VERSION = "flutter.dccon_download_completed_version"
        const val PREF_QUEUED_FOLDERS = "flutter.dccon_download_queued_folders"
        private const val PREFS_NAME = "FlutterSharedPreferences"
        private const val PREF_IMAGE_FOLDERS = "flutter.image_folders"
        private const val PREF_IMAGE_FOLDER_ORDER = "flutter.image_folder_order"
        private const val PREF_CURRENT_IMAGE_FOLDER = "flutter.current_image_folder"
        private const val PREF_DCCON_PACKAGES = "flutter.dccon_packages"
        private const val CHANNEL_ID = "dccon_downloads"
        private const val NOTIFICATION_ID = 4203
    }

    private val executor = Executors.newSingleThreadExecutor()
    private val pendingJobs = AtomicInteger(0)

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        prefs().edit()
            .putInt(PREF_ACTIVE, 0)
            .putString(PREF_QUEUED_FOLDERS, "[]")
            .apply()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val rawData = intent?.getStringExtra(EXTRA_DATA)
        if (rawData.isNullOrBlank()) {
            stopSelf(startId)
            return START_NOT_STICKY
        }

        val data = JSONObject(rawData)
        val queuedFolder = data.optString("folderName", data.optString("title", "디시콘"))
        val active = pendingJobs.incrementAndGet()
        addQueuedFolder(queuedFolder)
        prefs().edit().putInt(PREF_ACTIVE, active).apply()
        startForeground(
            NOTIFICATION_ID,
            buildNotification("디시콘 다운로드 준비 중", 0, 0, true),
        )

        executor.execute {
            try {
                downloadPackage(data)
            } catch (_: Exception) {
                showFinishedNotification("디시콘 다운로드에 실패했습니다.")
            } finally {
                val remaining = pendingJobs.decrementAndGet().coerceAtLeast(0)
                finishQueuedFolder(queuedFolder, remaining)
                if (remaining == 0) {
                    stopForeground(STOP_FOREGROUND_DETACH)
                    stopSelf()
                }
            }
        }
        return START_REDELIVER_INTENT
    }

    override fun onDestroy() {
        executor.shutdown()
        super.onDestroy()
    }

    private fun downloadPackage(data: JSONObject) {
        val packageId = data.optString("packageId")
        val title = data.optString("title", "디시콘")
        val folderName = data.optString("folderName", title)
        val icons = data.optJSONArray("icons") ?: JSONArray()
        val catalogUrls = jsonStringSet(data.optJSONArray("catalogUrls"))
        val existingUrls = jsonStringSet(data.optJSONArray("existingUrls"))
        val storedImages = File(applicationContext.getDir("flutter", Context.MODE_PRIVATE), "stored_images")
        storedImages.mkdirs()

        val record = packageRecord(packageId)
        val importedUrls = jsonStringSet(record.optJSONArray("importedUrls"))
        importedUrls.addAll(existingUrls)
        val savedPaths = mutableListOf<String>()
        var saved = 0

        for (index in 0 until icons.length()) {
            val icon = icons.optJSONObject(index) ?: continue
            val iconUrl = icon.optString("url")
            if (iconUrl.isBlank() || importedUrls.contains(iconUrl)) continue
            updateProgressNotification(title, index, icons.length(), icon.optString("title"))
            val savedFile = downloadIcon(
                packageId = packageId,
                iconUrl = iconUrl,
                requestedExtension = icon.optString("extension"),
                destination = storedImages,
            )
            if (savedFile != null) {
                importedUrls.add(iconUrl)
                savedPaths.add(savedFile.absolutePath)
                saved += 1
            }
        }

        persistResult(
            packageId = packageId,
            title = title,
            folderName = folderName,
            importedUrls = importedUrls,
            catalogUrls = catalogUrls,
            savedPaths = savedPaths,
        )
        showFinishedNotification(
            if (saved > 0) "$title: ${saved}개 다운로드 완료" else "$title: 새로운 항목이 없습니다.",
        )
    }

    private fun downloadIcon(
        packageId: String,
        iconUrl: String,
        requestedExtension: String,
        destination: File,
    ): File? {
        var connection: HttpURLConnection? = null
        return try {
            connection = URL(iconUrl).openConnection() as HttpURLConnection
            connection.connectTimeout = 15_000
            connection.readTimeout = 30_000
            connection.instanceFollowRedirects = true
            connection.setRequestProperty("User-Agent", "Mozilla/5.0 (Android) SideCord")
            connection.setRequestProperty("Referer", "https://dccon.dcinside.com/")
            connection.setRequestProperty("Accept", "image/*,*/*;q=0.8")
            connection.connect()
            if (connection.responseCode !in 200..299) return null

            val extension = normalizeExtension(requestedExtension, connection.contentType)
            val digest = MessageDigest.getInstance("SHA-256")
                .digest(iconUrl.toByteArray())
                .joinToString("") { "%02x".format(it) }
                .take(20)
            val output = File(destination, "dccon_${packageId}_$digest$extension")
            if (output.exists() && output.length() > 0) return output
            val temporary = File(destination, "${output.name}.part")
            connection.inputStream.use { input ->
                temporary.outputStream().use { stream -> input.copyTo(stream) }
            }
            if (!temporary.renameTo(output)) {
                temporary.copyTo(output, overwrite = true)
                temporary.delete()
            }
            output
        } catch (_: Exception) {
            null
        } finally {
            connection?.disconnect()
        }
    }

    @Synchronized
    private fun persistResult(
        packageId: String,
        title: String,
        folderName: String,
        importedUrls: Set<String>,
        catalogUrls: Set<String>,
        savedPaths: List<String>,
    ) {
        val preferences = prefs()
        val folders = jsonObject(preferences.getString(PREF_IMAGE_FOLDERS, null))
        val folderItems = folders.optJSONArray(folderName) ?: JSONArray()
        val knownPaths = jsonStringSet(folderItems)
        for (path in savedPaths) {
            if (knownPaths.add(path)) folderItems.put(path)
        }
        folders.put(folderName, folderItems)

        val order = jsonArray(preferences.getString(PREF_IMAGE_FOLDER_ORDER, null))
        val knownFolders = jsonStringSet(order)
        if (knownFolders.add(folderName)) order.put(folderName)

        val packages = jsonObject(preferences.getString(PREF_DCCON_PACKAGES, null))
        packages.put(
            packageId,
            JSONObject()
                .put("title", title)
                .put("folderName", folderName)
                .put("importedUrls", JSONArray(importedUrls.toList()))
                .put("catalogUrls", JSONArray(catalogUrls.toList()))
                .put("identityVersion", 2)
                .put("updatedAt", System.currentTimeMillis()),
        )

        preferences.edit()
            .putString(PREF_IMAGE_FOLDERS, folders.toString())
            .putString(PREF_IMAGE_FOLDER_ORDER, order.toString())
            .putString(PREF_CURRENT_IMAGE_FOLDER, folderName)
            .putString(PREF_DCCON_PACKAGES, packages.toString())
            .apply()
    }

    private fun packageRecord(packageId: String): JSONObject {
        val packages = jsonObject(prefs().getString(PREF_DCCON_PACKAGES, null))
        return packages.optJSONObject(packageId) ?: JSONObject()
    }

    @Synchronized
    private fun addQueuedFolder(folderName: String) {
        val preferences = prefs()
        val folders = jsonStringSet(jsonArray(preferences.getString(PREF_QUEUED_FOLDERS, null)))
        folders.add(folderName)
        preferences.edit().putString(PREF_QUEUED_FOLDERS, JSONArray(folders.toList()).toString()).commit()
    }

    @Synchronized
    private fun finishQueuedFolder(folderName: String, remaining: Int) {
        val preferences = prefs()
        val folders = jsonStringSet(jsonArray(preferences.getString(PREF_QUEUED_FOLDERS, null)))
        folders.remove(folderName)
        val nextVersion = preferences.getInt(PREF_COMPLETED_VERSION, 0) + 1
        preferences.edit()
            .putString(PREF_QUEUED_FOLDERS, JSONArray(folders.toList()).toString())
            .putInt(PREF_ACTIVE, remaining)
            .putInt(PREF_COMPLETED_VERSION, nextVersion)
            .commit()
    }

    private fun updateProgressNotification(title: String, completed: Int, total: Int, iconTitle: String) {
        val label = iconTitle.ifBlank { title }
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(
            NOTIFICATION_ID,
            buildNotification("$label 다운로드 중", completed, total, total <= 0),
        )
    }

    private fun showFinishedNotification(message: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(
            NOTIFICATION_ID,
            buildNotification(message, 0, 0, false),
        )
    }

    private fun buildNotification(
        message: String,
        completed: Int,
        total: Int,
        indeterminate: Boolean,
    ): android.app.Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = launchIntent?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("SideCord 디시콘")
            .setContentText(message)
            .setContentIntent(pendingIntent)
            .setOnlyAlertOnce(true)
            .setOngoing(total > 0 || indeterminate)
            .setProgress(total, completed, indeterminate)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "디시콘 다운로드",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "백그라운드 디시콘 다운로드 진행 상황"
            },
        )
    }

    private fun prefs() = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    private fun jsonObject(value: String?): JSONObject = try {
        if (value.isNullOrBlank()) JSONObject() else JSONObject(value)
    } catch (_: Exception) {
        JSONObject()
    }

    private fun jsonArray(value: String?): JSONArray = try {
        if (value.isNullOrBlank()) JSONArray() else JSONArray(value)
    } catch (_: Exception) {
        JSONArray()
    }

    private fun jsonStringSet(array: JSONArray?): MutableSet<String> {
        val result = linkedSetOf<String>()
        if (array == null) return result
        for (index in 0 until array.length()) {
            val value = array.optString(index)
            if (value.isNotBlank()) result.add(value)
        }
        return result
    }

    private fun normalizeExtension(requested: String, contentType: String?): String {
        val clean = requested.trim().removePrefix(".").lowercase()
        if (clean in setOf("gif", "png", "jpg", "jpeg", "webp")) return ".$clean"
        val type = contentType.orEmpty().lowercase()
        return when {
            "gif" in type -> ".gif"
            "webp" in type -> ".webp"
            "jpeg" in type || "jpg" in type -> ".jpg"
            else -> ".png"
        }
    }
}
