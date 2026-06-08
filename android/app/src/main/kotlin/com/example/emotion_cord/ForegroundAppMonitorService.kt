package com.example.emotion_cord

import android.app.ActivityManager
import android.app.AppOpsManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Process
import android.provider.Settings

class ForegroundAppMonitorService : Service() {
    companion object {
        const val ACTION_START = "com.example.emotion_cord.action.START_MONITOR"
        const val ACTION_STOP = "com.example.emotion_cord.action.STOP_MONITOR"
        const val ACTION_SUPPRESS_OVERLAY = "com.example.emotion_cord.action.SUPPRESS_OVERLAY"
        const val EXTRA_SUPPRESS_MS = "extra_suppress_ms"
        private const val PREFS_NAME = "FlutterSharedPreferences"
        private const val PREF_OVERLAY_ENABLED = "flutter.overlay_enabled"
    }

    private val handler = Handler(Looper.getMainLooper())
    private var isMonitoring = false
    private var lastForegroundApp: String? = null
    private var overlayActive = false
    private var cachedLauncherPackage: String? = null
    private var suppressUntilMs = 0L
    private var nextDelayMs = 2000L
    private var fastDelayMs = 1000L
    private var slowDelayMs = 2000L
    private var lastDiscordSeenMs = 0L
    private val discordGraceMs = 5000L
    private var delaysLoaded = false
    private var activityManager: ActivityManager? = null
    private var usageStatsManager: android.app.usage.UsageStatsManager? = null
    private var appOpsManager: AppOpsManager? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        appOpsManager = getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            usageStatsManager = getSystemService(Context.USAGE_STATS_SERVICE) as android.app.usage.UsageStatsManager
        } else {
            activityManager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                setOverlayEnabled(true)
                startMonitoring()
            }
            ACTION_STOP -> {
                setOverlayEnabled(false)
                stopMonitoring()
                stopSelf()
            }
            ACTION_SUPPRESS_OVERLAY -> {
                val durationMs = intent.getLongExtra(EXTRA_SUPPRESS_MS, 0L)
                suppressUntilMs = maxOf(suppressUntilMs, System.currentTimeMillis() + durationMs)
                hideOverlayIfActive()
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        stopMonitoring()
        super.onDestroy()
    }

    private fun startMonitoring() {
        if (isMonitoring) {
            checkForegroundApp()
            return
        }
        isMonitoring = true
        handler.post(monitoringRunnable)
    }

    private fun stopMonitoring() {
        isMonitoring = false
        handler.removeCallbacks(monitoringRunnable)
        hideOverlayIfActive()
    }

    private val monitoringRunnable = object : Runnable {
        override fun run() {
            if (!isMonitoring) return
            checkForegroundApp()
            handler.postDelayed(this, nextDelayMs)
        }
    }

    private fun checkForegroundApp() {
        try {
            loadMonitoringDelays()
            if (isAccessibilityServiceEnabled()) {
                nextDelayMs = slowDelayMs
                return
            }
            if (!isOverlayEnabled()) {
                hideOverlayIfActive()
                nextDelayMs = slowDelayMs
                return
            }
            if (System.currentTimeMillis() < suppressUntilMs) {
                hideOverlayIfActive()
                nextDelayMs = fastDelayMs
                return
            }
            if (!hasUsageAccess()) {
                hideOverlayIfActive()
                nextDelayMs = slowDelayMs
                return
            }

            val foregroundAppName = resolveForegroundPackage()
            if (foregroundAppName.isNullOrEmpty()) {
                nextDelayMs = fastDelayMs
                return
            }

            val launcherPackage = cachedLauncherPackage ?: getDefaultLauncherPackage().also {
                cachedLauncherPackage = it
            }
            if (foregroundAppName != lastForegroundApp) {
                lastForegroundApp = foregroundAppName
                if (foregroundAppName != packageName && foregroundAppName != launcherPackage) {
                    persistLastForegroundApp(foregroundAppName)
                }
            }

            val shouldShow = isDiscordPackage(foregroundAppName) &&
                foregroundAppName != launcherPackage
            if (shouldShow) {
                showOverlayIfNeeded()
                lastDiscordSeenMs = System.currentTimeMillis()
                nextDelayMs = fastDelayMs
            } else {
                hideOverlayIfActive()
                val now = System.currentTimeMillis()
                nextDelayMs = if (now - lastDiscordSeenMs <= discordGraceMs) {
                    fastDelayMs
                } else {
                    slowDelayMs
                }
            }
        } catch (e: Exception) {
            nextDelayMs = slowDelayMs
        }
    }

    private fun resolveForegroundPackage(): String? {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val manager = usageStatsManager
                    ?: (getSystemService(Context.USAGE_STATS_SERVICE) as android.app.usage.UsageStatsManager).also {
                        usageStatsManager = it
                    }
                val endTime = System.currentTimeMillis()
                val startTime = endTime - 30000
                val usageEvents = manager.queryEvents(startTime, endTime)
                var lastPackageName: String? = null
                var lastTimestamp = 0L
                val event = android.app.usage.UsageEvents.Event()
                while (usageEvents.hasNextEvent()) {
                    usageEvents.getNextEvent(event)
                    if (event.eventType == android.app.usage.UsageEvents.Event.MOVE_TO_FOREGROUND ||
                        event.eventType == android.app.usage.UsageEvents.Event.ACTIVITY_RESUMED) {
                        if (event.timeStamp > lastTimestamp) {
                            lastTimestamp = event.timeStamp
                            lastPackageName = event.packageName
                        }
                    }
                }
                lastPackageName ?: manager.queryUsageStats(
                    android.app.usage.UsageStatsManager.INTERVAL_BEST,
                    startTime,
                    endTime
                ).maxByOrNull { it.lastTimeUsed }?.packageName
            } else {
                @Suppress("DEPRECATION")
                activityManager?.runningAppProcesses?.firstOrNull()?.processName
            }
        } catch (e: Exception) {
            null
        }
    }

    private fun loadMonitoringDelays() {
        if (delaysLoaded) return
        fastDelayMs = 1000L
        slowDelayMs = 2000L
        delaysLoaded = true
    }

    private fun setOverlayEnabled(enabled: Boolean) {
        try {
            getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(PREF_OVERLAY_ENABLED, enabled)
                .apply()
        } catch (e: Exception) {
            // Silently handle errors
        }
    }

    private fun isOverlayEnabled(): Boolean {
        return try {
            getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .getBoolean(PREF_OVERLAY_ENABLED, false)
        } catch (e: Exception) {
            false
        }
    }

    private fun hasUsageAccess(): Boolean {
        return try {
            val appOps = appOpsManager
                ?: (getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager).also {
                    appOpsManager = it
                }
            val mode = appOps.checkOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                Process.myUid(),
                packageName
            )
            mode == AppOpsManager.MODE_ALLOWED
        } catch (e: Exception) {
            false
        }
    }

    private fun showOverlayIfNeeded() {
        if (overlayActive) return
        try {
            overlayActive = true
            val intent = Intent(this, OverlayService::class.java).apply {
                action = OverlayService.ACTION_SHOW
                putExtra(OverlayService.EXTRA_IMAGE_PATH, "")
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
        } catch (e: Exception) {
            overlayActive = false
        }
    }

    private fun persistLastForegroundApp(packageName: String?) {
        try {
            getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putString("flutter.last_foreground_app", packageName ?: "")
                .apply()
        } catch (e: Exception) {
            // Silently handle errors
        }
    }

    private fun isDiscordPackage(packageName: String): Boolean {
        return packageName == "com.discord" || packageName == "com.discord.android"
    }

    private fun getDefaultLauncherPackage(): String? {
        return try {
            val intent = Intent(Intent.ACTION_MAIN)
            intent.addCategory(Intent.CATEGORY_HOME)
            packageManager.resolveActivity(intent, 0)?.activityInfo?.packageName
        } catch (e: Exception) {
            null
        }
    }

    private fun hideOverlayIfActive() {
        if (!overlayActive) return
        try {
            overlayActive = false
            val intent = Intent(this, OverlayService::class.java).apply {
                action = OverlayService.ACTION_HIDE
            }
            startService(intent)
        } catch (e: Exception) {
            // Silently handle errors
        }
    }

    private fun isAccessibilityServiceEnabled(): Boolean {
        return try {
            val enabled = Settings.Secure.getString(
                contentResolver,
                Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
            ) ?: return false
            val serviceId = "$packageName/${DiscordAccessibilityService::class.java.name}"
            enabled.split(':').any { it.equals(serviceId, ignoreCase = true) }
        } catch (e: Exception) {
            false
        }
    }
}
