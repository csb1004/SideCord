package com.example.emotion_cord

import android.app.AppOpsManager
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.os.Process
import android.provider.Settings
import android.net.Uri
import androidx.core.content.ContextCompat
import androidx.core.app.ActivityCompat
import android.Manifest
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
	private val CHANNEL = "com.yourapp/overlay"
	private var methodChannel: MethodChannel? = null
	private val PERMISSION_REQUEST_CODE = 100

	override fun onCreate(savedInstanceState: Bundle?) {
		super.onCreate(savedInstanceState)
		
		// Request necessary permissions
		requestRequiredPermissions()
	}

	override fun onPause() {
		super.onPause()
	}

	override fun onStop() {
		super.onStop()
	}


	private fun requestRequiredPermissions() {
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
			// SYSTEM_ALERT_WINDOW is a special permission that requires going to Settings
			if (!Settings.canDrawOverlays(this)) {
				val intent = Intent(
					Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
					android.net.Uri.parse("package:$packageName")
				)
				startActivity(intent)
			}

			// Usage Access permission for foreground app detection
			val appOps = getSystemService(android.content.Context.APP_OPS_SERVICE) as AppOpsManager
			val mode = appOps.checkOpNoThrow(
				AppOpsManager.OPSTR_GET_USAGE_STATS,
				Process.myUid(),
				packageName
			)
			if (mode != AppOpsManager.MODE_ALLOWED) {
				val intent = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
				startActivity(intent)
			}

			// Request ignore battery optimizations for long-running overlay
			val powerManager = getSystemService(android.content.Context.POWER_SERVICE) as PowerManager
			if (!powerManager.isIgnoringBatteryOptimizations(packageName)) {
				val intent = Intent(
					Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
					Uri.parse("package:$packageName")
				)
				startActivity(intent)
			}
			
			// Request other dangerous permissions
			val permissionsToRequest = mutableListOf<String>()
			if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
				if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
					!= android.content.pm.PackageManager.PERMISSION_GRANTED) {
					permissionsToRequest.add(Manifest.permission.POST_NOTIFICATIONS)
				}
			}
			if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_EXTERNAL_STORAGE) 
				!= android.content.pm.PackageManager.PERMISSION_GRANTED) {
				permissionsToRequest.add(Manifest.permission.READ_EXTERNAL_STORAGE)
			}
			
			if (permissionsToRequest.isNotEmpty()) {
				ActivityCompat.requestPermissions(this, permissionsToRequest.toTypedArray(), PERMISSION_REQUEST_CODE)
			}
		}
	}

	override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
		super.onRequestPermissionsResult(requestCode, permissions, grantResults)
		when (requestCode) {
			PERMISSION_REQUEST_CODE -> {
				// Handle permission results
				for (i in permissions.indices) {
					if (permissions[i] == Manifest.permission.SYSTEM_ALERT_WINDOW && grantResults[i] == android.content.pm.PackageManager.PERMISSION_GRANTED) {
						// SYSTEM_ALERT_WINDOW granted, start overlay
					}
				}
			}
		}
	}

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)
		methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
		methodChannel!!.setMethodCallHandler { call, result ->
			try {
				when (call.method) {
					"setImageFolders" -> {
						try {
							val data = call.argument<String>("data") ?: "{}"
							val prefs = getSharedPreferences("FlutterSharedPreferences", android.content.Context.MODE_PRIVATE)
							prefs.edit().putString("flutter.image_folders", data).apply()
							result.success(true)
						} catch (e: Exception) {
							result.error("SET_IMAGE_FOLDERS_FAILED", e.message, null)
						}
					}
					"setImageFolderOrder" -> {
						try {
							val data = call.argument<String>("data") ?: "[]"
							val prefs = getSharedPreferences("FlutterSharedPreferences", android.content.Context.MODE_PRIVATE)
							prefs.edit().putString("flutter.image_folder_order", data).apply()
							result.success(true)
						} catch (e: Exception) {
							result.error("SET_IMAGE_FOLDER_ORDER_FAILED", e.message, null)
						}
					}
					"setTextFolders" -> {
						try {
							val data = call.argument<String>("data") ?: "{}"
							val prefs = getSharedPreferences("FlutterSharedPreferences", android.content.Context.MODE_PRIVATE)
							prefs.edit().putString("flutter.text_folders", data).apply()
							result.success(true)
						} catch (e: Exception) {
							result.error("SET_TEXT_FOLDERS_FAILED", e.message, null)
						}
					}
					"setTextFolderOrder" -> {
						try {
							val data = call.argument<String>("data") ?: "[]"
							val prefs = getSharedPreferences("FlutterSharedPreferences", android.content.Context.MODE_PRIVATE)
							prefs.edit().putString("flutter.text_folder_order", data).apply()
							result.success(true)
						} catch (e: Exception) {
							result.error("SET_TEXT_FOLDER_ORDER_FAILED", e.message, null)
						}
					}
					"setOverlaySettings" -> {
						try {
							val sizeDp = call.argument<Double>("sizeDp") ?: 72.0
							val iconPath = call.argument<String>("iconPath")
							val borderDp = call.argument<Double>("borderDp") ?: 10.0
							val thumbDp = call.argument<Double>("thumbDp") ?: 64.0
							val fastMs = (call.argument<Number>("fastMs")?.toLong() ?: 300L)
							val slowMs = (call.argument<Number>("slowMs")?.toLong() ?: 4000L)
							val prefs = getSharedPreferences("FlutterSharedPreferences", android.content.Context.MODE_PRIVATE)
							prefs.edit()
								.putFloat("flutter.overlay_size_dp", sizeDp.toFloat())
								.putString("flutter.overlay_icon_path", iconPath)
								.putFloat("flutter.overlay_border_dp", borderDp.toFloat())
								.putFloat("flutter.overlay_thumb_dp", thumbDp.toFloat())
								.putLong("flutter.monitor_fast_ms", fastMs)
								.putLong("flutter.monitor_slow_ms", slowMs)
								.apply()
							val intent = Intent(this, OverlayService::class.java)
							intent.action = OverlayService.ACTION_UPDATE_SETTINGS
							startService(intent)
							result.success(true)
						} catch (e: Exception) {
							result.error("SET_OVERLAY_SETTINGS_FAILED", e.message, null)
						}
					}
					"setCurrentImageFolder" -> {
						try {
							val name = call.argument<String>("name") ?: ""
							val prefs = getSharedPreferences("FlutterSharedPreferences", android.content.Context.MODE_PRIVATE)
							prefs.edit().putString("flutter.current_image_folder", name).apply()
							result.success(true)
						} catch (e: Exception) {
							result.error("SET_CURRENT_IMAGE_FOLDER_FAILED", e.message, null)
						}
					}
					"setCurrentTextFolder" -> {
						try {
							val name = call.argument<String>("name") ?: ""
							val prefs = getSharedPreferences("FlutterSharedPreferences", android.content.Context.MODE_PRIVATE)
							prefs.edit().putString("flutter.current_text_folder", name).apply()
							result.success(true)
						} catch (e: Exception) {
							result.error("SET_CURRENT_TEXT_FOLDER_FAILED", e.message, null)
						}
					}
					"startMonitoring" -> {
						val intent = Intent(this, ForegroundAppMonitorService::class.java)
						intent.action = ForegroundAppMonitorService.ACTION_START
						try {
							startService(intent)
							result.success(true)
						} catch (e: Exception) {
							result.error("START_MONITORING_FAILED", e.message, null)
						}
					}
					"stopMonitoring" -> {
						val intent = Intent(this, ForegroundAppMonitorService::class.java)
						intent.action = ForegroundAppMonitorService.ACTION_STOP
						try {
							stopService(intent)
							result.success(true)
						} catch (e: Exception) {
							result.error("STOP_MONITORING_FAILED", e.message, null)
						}
					}
					else -> result.notImplemented()
				}
			} catch (e: Exception) {
				result.error("UNEXPECTED_ERROR", e.message, null)
			}
		}
	}

}

