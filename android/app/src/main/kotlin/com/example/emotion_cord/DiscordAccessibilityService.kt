package com.example.emotion_cord

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.content.Intent
import android.view.accessibility.AccessibilityEvent

class DiscordAccessibilityService : AccessibilityService() {
    companion object {
        private const val PREFS_NAME = "FlutterSharedPreferences"
        private const val PREF_OVERLAY_ENABLED = "flutter.overlay_enabled"
    }

    private var overlayShown = false
    private var lastPackage: String? = null
    private var lastEventAtMs = 0L
    private val debounceMs = 500L

    override fun onServiceConnected() {
        super.onServiceConnected()
        lastPackage = null
        overlayShown = false
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        if (event.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return

        val eventPackage = event.packageName?.toString() ?: return
        if (shouldIgnorePackage(eventPackage)) return

        val now = System.currentTimeMillis()
        if (eventPackage == lastPackage && (now - lastEventAtMs) < debounceMs) {
            return
        }

        lastPackage = eventPackage
        lastEventAtMs = now
        if (isOverlayEnabled() && isDiscordPackage(eventPackage)) {
            showOverlay()
        } else {
            hideOverlay()
        }
    }

    override fun onInterrupt() {
        // No-op
    }

    private fun showOverlay() {
        if (overlayShown) return
        try {
            overlayShown = true
            val intent = Intent(this, OverlayService::class.java).apply {
                action = OverlayService.ACTION_SHOW
                putExtra(OverlayService.EXTRA_IMAGE_PATH, "")
            }
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
        } catch (e: Exception) {
            overlayShown = false
        }
    }

    private fun hideOverlay() {
        if (!overlayShown) return
        try {
            overlayShown = false
            val intent = Intent(this, OverlayService::class.java).apply {
                action = OverlayService.ACTION_HIDE
            }
            startService(intent)
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

    private fun isDiscordPackage(name: String): Boolean {
        return name == "com.discord" || name == "com.discord.android"
    }

    private fun shouldIgnorePackage(name: String): Boolean {
        val lower = name.lowercase()
        return name == packageName ||
            name == "android" ||
            name == "com.android.systemui" ||
            lower.contains("inputmethod") ||
            lower.contains("keyboard")
    }
}
