package com.example.emotion_cord

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.ColorFilter
import android.graphics.ImageDecoder
import android.graphics.Movie
import android.graphics.Paint
import android.graphics.PixelFormat
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import android.graphics.Color
import android.graphics.drawable.Animatable
import android.graphics.drawable.AnimatedImageDrawable
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.provider.Settings
import android.view.Gravity
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.View
import android.graphics.Rect
import android.view.WindowManager
import android.widget.ArrayAdapter
import android.widget.BaseAdapter
import android.widget.FrameLayout
import android.widget.GridView
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.TextView
import android.widget.Toast
import android.view.ViewGroup
import org.json.JSONArray
import org.json.JSONObject
import androidx.core.content.FileProvider
import androidx.core.graphics.drawable.RoundedBitmapDrawableFactory
import android.content.SharedPreferences
import java.io.File
import kotlin.math.max

@Suppress("DEPRECATION")
private class MovieGifDrawable(file: File) : Drawable(), Animatable {
    private val movie: Movie = file.inputStream().use { input ->
        Movie.decodeStream(input) ?: throw IllegalArgumentException("Invalid GIF")
    }
    private val paint = Paint(Paint.FILTER_BITMAP_FLAG)
    private val frameDelayMs = 16L
    private var startTimeMs = 0L
    private var running = false
    private val durationMs = if (movie.duration() > 0) movie.duration() else 1000

    private val frameUpdater = object : Runnable {
        override fun run() {
            if (!running) return
            invalidateSelf()
            scheduleSelf(this, SystemClock.uptimeMillis() + frameDelayMs)
        }
    }

    override fun draw(canvas: Canvas) {
        if (bounds.isEmpty) return
        val now = SystemClock.uptimeMillis()
        if (startTimeMs == 0L) {
            startTimeMs = now
        }

        val frameTime = ((now - startTimeMs) % durationMs).toInt()
        movie.setTime(frameTime)

        val movieWidth = movie.width().coerceAtLeast(1)
        val movieHeight = movie.height().coerceAtLeast(1)
        val scale = max(
            bounds.width() / movieWidth.toFloat(),
            bounds.height() / movieHeight.toFloat()
        )
        val dx = bounds.left + ((bounds.width() - movieWidth * scale) / 2f)
        val dy = bounds.top + ((bounds.height() - movieHeight * scale) / 2f)

        canvas.save()
        canvas.clipRect(bounds)
        canvas.translate(dx, dy)
        canvas.scale(scale, scale)
        movie.draw(canvas, 0f, 0f, paint)
        canvas.restore()
    }

    override fun setAlpha(alpha: Int) {
        paint.alpha = alpha
    }

    override fun setColorFilter(colorFilter: ColorFilter?) {
        paint.colorFilter = colorFilter
    }

    override fun getOpacity(): Int = PixelFormat.TRANSLUCENT

    override fun getIntrinsicWidth(): Int = movie.width()

    override fun getIntrinsicHeight(): Int = movie.height()

    override fun start() {
        if (running) return
        running = true
        startTimeMs = SystemClock.uptimeMillis()
        scheduleSelf(frameUpdater, startTimeMs + frameDelayMs)
    }

    override fun stop() {
        running = false
        unscheduleSelf(frameUpdater)
    }

    override fun isRunning(): Boolean = running
}

private data class OverlayFolderItem(
    val name: String,
    val count: Int,
    val previewPath: String?
)

class OverlayService : Service() {
    companion object {
        const val ACTION_SHOW = "com.example.emotion_cord.action.SHOW_OVERLAY"
        const val ACTION_HIDE = "com.example.emotion_cord.action.HIDE_OVERLAY"
        const val ACTION_UPDATE_SETTINGS = "com.example.emotion_cord.action.UPDATE_SETTINGS"
        const val ACTION_OPEN_GALLERY = "com.example.emotion_cord.action.OPEN_GALLERY"
        const val ACTION_OPEN_APP = "com.example.emotion_cord.action.OPEN_APP"
        const val EXTRA_IMAGE_PATH = "extra_image_path"
        private const val RECENT_FOLDER_NAME = "최근 사용"
        private const val RECENT_FOLDER_LIMIT = 100
    }

    private var windowManager: WindowManager? = null
    private var overlayView: View? = null
    private var galleryView: View? = null
    private var lastImagePath: String? = null
    private var overlayParams: WindowManager.LayoutParams? = null
    private var touchStartX = 0f
    private var touchStartY = 0f
    private var viewStartX = 0
    private var viewStartY = 0
    private var isDragging = false
    private var closeTargetView: View? = null
    private var closeTargetParams: WindowManager.LayoutParams? = null
    private var closeTargetSizePx = 0
    private var isOverCloseTarget = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            when (intent?.action) {
                ACTION_SHOW -> {
                    val path = intent.getStringExtra(EXTRA_IMAGE_PATH)
                    // Check if we have permission to draw overlays
                    // But don't return immediately if permission is missing - try anyway
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        Settings.canDrawOverlays(this)
                    }
                    
                    showOverlay(path)
                }
                ACTION_HIDE -> {
                    removeOverlay()
                    stopForeground(true)
                    stopSelf()
                }
                ACTION_UPDATE_SETTINGS -> {
                    applyOverlaySettings()
                }
                ACTION_OPEN_GALLERY -> {
                    ensureForeground()
                    showGalleryOverlay()
                }
                ACTION_OPEN_APP -> {
                    ensureForeground()
                    openHostApp()
                }
            }
        } catch (e: Exception) {
            stopForeground(true)
            stopSelf()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        removeGalleryOverlay()
        removeOverlay()
        stopForeground(true)
        super.onDestroy()
    }

    private fun showGalleryOverlay() {
        if (galleryView != null) {
            return
        }
        try {
            removeOverlay()
            ensureForeground()
            windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
            val inflater = getSystemService(Context.LAYOUT_INFLATER_SERVICE) as LayoutInflater
            galleryView = inflater.inflate(R.layout.overlay_gallery, null)

            val root = galleryView!!.findViewById<View>(R.id.gallery_root)
            val closeBtn = galleryView!!.findViewById<ImageButton>(R.id.gallery_close)
            val gridView = galleryView!!.findViewById<GridView>(R.id.gallery_grid)
            val textListView = galleryView!!.findViewById<ListView>(R.id.gallery_text_list)
            val photosTab = galleryView!!.findViewById<TextView>(R.id.gallery_tab_photos)
            val textsTab = galleryView!!.findViewById<TextView>(R.id.gallery_tab_texts)
            val folderLabel = galleryView!!.findViewById<TextView>(R.id.gallery_folder_label)
            val folderChange = galleryView!!.findViewById<TextView>(R.id.gallery_folder_change)
            val folderListView = galleryView!!.findViewById<ListView>(R.id.gallery_folder_list)
            val selectionBar = galleryView!!.findViewById<View>(R.id.gallery_selection_bar)
            val selectionCount = galleryView!!.findViewById<TextView>(R.id.gallery_selection_count)
            val selectionClear = galleryView!!.findViewById<TextView>(R.id.gallery_selection_clear)
            val selectionSend = galleryView!!.findViewById<TextView>(R.id.gallery_selection_send)
            gridView.isClickable = true
            gridView.isFocusable = true
            gridView.isFocusableInTouchMode = true
            textListView.isClickable = true
            textListView.isFocusable = true
            textListView.isFocusableInTouchMode = true
            folderListView.isClickable = true
            folderListView.isFocusable = true
            folderListView.isFocusableInTouchMode = true

            var showPhotos = true
            var showFolders = false

            val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)

            fun resolveCurrentFolder(isPhotos: Boolean): String {
                val key = if (isPhotos) "flutter.current_image_folder" else "flutter.current_text_folder"
                val list = loadFolderNames(
                    if (isPhotos) "flutter.image_folders" else "flutter.text_folders",
                    if (isPhotos) "flutter.image_folder_order" else "flutter.text_folder_order"
                )
                val current = prefs.getString(key, "") ?: ""
                return if (current.isNotEmpty() && list.contains(current)) current
                else list.firstOrNull() ?: ""
            }

            fun setCurrentFolder(isPhotos: Boolean, name: String) {
                val key = if (isPhotos) "flutter.current_image_folder" else "flutter.current_text_folder"
                prefs.edit().putString(key, name).apply()
            }

            val imageItems = mutableListOf<String>()
            val textItems = mutableListOf<String>()
            val folderItems = mutableListOf<OverlayFolderItem>()
            val selectedImagePaths = linkedSetOf<String>()

            fun updateSelectionUi() {
                selectionBar.visibility = if (showPhotos && selectedImagePaths.isNotEmpty() && !showFolders) {
                    View.VISIBLE
                } else {
                    View.GONE
                }
                selectionCount.text = "${selectedImagePaths.size}개 선택"
            }

            gridView.adapter = object : BaseAdapter() {
                override fun getCount(): Int = imageItems.size
                override fun getItem(position: Int): Any = imageItems[position]
                override fun getItemId(position: Int): Long = position.toLong()

                override fun getView(position: Int, convertView: View?, parent: ViewGroup?): View {
                    val itemView = convertView ?: LayoutInflater.from(parent?.context)
                        .inflate(R.layout.overlay_gallery_item, parent, false)
                    val imageView = itemView.findViewById<ImageView>(R.id.gallery_item_image)
                    val path = imageItems[position]
                    val file = File(path)
                    itemView.alpha = if (selectedImagePaths.contains(path)) 0.56f else 1.0f
                    itemView.setBackgroundColor(
                        if (selectedImagePaths.contains(path)) Color.argb(70, 44, 118, 255)
                        else Color.TRANSPARENT
                    )
                    if (file.exists()) {
                        val sizePx = getOverlayThumbPx()
                        loadImageIntoView(imageView, file, sizePx, sizePx)
                    } else {
                        clearImageView(imageView)
                        imageView.setBackgroundColor(android.graphics.Color.LTGRAY)
                    }
                    return itemView
                }
            }

            gridView.setOnItemClickListener { _, _, position, _ ->
                val path = imageItems[position]
                if (selectedImagePaths.isEmpty()) {
                    shareImageToDiscord(path)
                } else {
                    if (!selectedImagePaths.add(path)) {
                        selectedImagePaths.remove(path)
                    }
                    updateSelectionUi()
                    (gridView.adapter as BaseAdapter).notifyDataSetChanged()
                }
            }
            gridView.setOnItemLongClickListener { _, _, position, _ ->
                val path = imageItems[position]
                if (!selectedImagePaths.add(path)) {
                    selectedImagePaths.remove(path)
                }
                updateSelectionUi()
                (gridView.adapter as BaseAdapter).notifyDataSetChanged()
                true
            }

            val textAdapter = ArrayAdapter(
                this,
                android.R.layout.simple_list_item_1,
                textItems
            )
            textListView.adapter = textAdapter
            textListView.setOnItemClickListener { _, _, position, _ ->
                val text = textItems[position]
                shareTextToDiscord(text)
            }

            val folderAdapter = object : BaseAdapter() {
                override fun getCount(): Int = folderItems.size
                override fun getItem(position: Int): Any = folderItems[position]
                override fun getItemId(position: Int): Long = position.toLong()

                override fun getView(position: Int, convertView: View?, parent: ViewGroup?): View {
                    val context = parent?.context ?: this@OverlayService
                    val item = folderItems[position]
                    val density = resources.displayMetrics.density
                    val row = (convertView as? LinearLayout) ?: LinearLayout(context).apply {
                        orientation = LinearLayout.HORIZONTAL
                        gravity = Gravity.CENTER_VERTICAL
                        val padH = (12 * density).toInt()
                        val padV = (8 * density).toInt()
                        setPadding(padH, padV, padH, padV)

                        val image = ImageView(context).apply {
                            id = View.generateViewId()
                            scaleType = ImageView.ScaleType.CENTER_CROP
                            background = GradientDrawable().apply {
                                shape = GradientDrawable.RECTANGLE
                                cornerRadius = 10 * density
                                setColor(Color.rgb(238, 238, 238))
                            }
                            clipToOutline = true
                        }
                        val imageParams = LinearLayout.LayoutParams(
                            (48 * density).toInt(),
                            (48 * density).toInt()
                        )
                        addView(image, imageParams)

                        val text = TextView(context).apply {
                            id = View.generateViewId()
                            textSize = 15f
                            setTextColor(Color.rgb(32, 32, 32))
                            setPadding((12 * density).toInt(), 0, 0, 0)
                        }
                        val textParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
                        addView(text, textParams)
                    }

                    val imageView = row.getChildAt(0) as ImageView
                    val textView = row.getChildAt(1) as TextView
                    textView.text = "${item.name} · ${item.count}개"
                    val preview = item.previewPath
                    if (!preview.isNullOrEmpty() && File(preview).exists()) {
                        loadImageIntoView(imageView, File(preview), getOverlayThumbPx(), getOverlayThumbPx())
                    } else {
                        clearImageView(imageView)
                        imageView.setImageResource(
                            if (showPhotos) android.R.drawable.ic_menu_gallery
                            else android.R.drawable.ic_menu_edit
                        )
                    }
                    return row
                }
            }
            folderListView.adapter = folderAdapter

            fun refreshFolderList() {
                folderItems.clear()
                val list = loadFolderNames(
                    if (showPhotos) "flutter.image_folders" else "flutter.text_folders",
                    if (showPhotos) "flutter.image_folder_order" else "flutter.text_folder_order"
                )
                folderItems.addAll(list.map { name ->
                    val items = if (showPhotos) {
                        loadImagePathsForFolder(name)
                    } else {
                        loadTextItemsForFolder(name)
                    }
                    OverlayFolderItem(
                        name = name,
                        count = items.size,
                        previewPath = if (showPhotos) items.firstOrNull { File(it).exists() } else null
                    )
                })
                folderAdapter.notifyDataSetChanged()
            }

            fun refreshContent() {
                val currentFolder = resolveCurrentFolder(showPhotos)
                folderLabel.text = if (currentFolder.isNotEmpty()) currentFolder else "폴더 선택"

                if (showPhotos) {
                    imageItems.clear()
                    imageItems.addAll(loadImagePathsForFolder(currentFolder))
                } else {
                    textItems.clear()
                    textItems.addAll(loadTextItemsForFolder(currentFolder))
                }
                (gridView.adapter as BaseAdapter).notifyDataSetChanged()
                textAdapter.notifyDataSetChanged()
                updateSelectionUi()

                gridView.visibility = if (showPhotos && !showFolders) View.VISIBLE else View.GONE
                textListView.visibility = if (!showPhotos && !showFolders) View.VISIBLE else View.GONE
                folderListView.visibility = if (showFolders) View.VISIBLE else View.GONE
            }

            fun setTabState(photos: Boolean) {
                showPhotos = photos
                selectedImagePaths.clear()
                photosTab.alpha = if (showPhotos) 1f else 0.6f
                textsTab.alpha = if (showPhotos) 0.6f else 1f
                prefs.edit().putString(
                    "flutter.overlay_last_tab",
                    if (showPhotos) "photos" else "texts"
                ).apply()
                refreshFolderList()
                var currentFolder = resolveCurrentFolder(showPhotos)
                if (currentFolder.isEmpty() && folderItems.isNotEmpty()) {
                    currentFolder = folderItems.first().name
                    setCurrentFolder(showPhotos, currentFolder)
                }
                showFolders = currentFolder.isEmpty()
                refreshContent()
            }

            folderListView.setOnItemClickListener { _, _, position, _ ->
                val name = folderItems[position].name
                setCurrentFolder(showPhotos, name)
                selectedImagePaths.clear()
                showFolders = false
                refreshContent()
            }

            folderChange.setOnClickListener {
                showFolders = !showFolders
                refreshFolderList()
                refreshContent()
            }

            val lastTab = prefs.getString("flutter.overlay_last_tab", "photos") ?: "photos"
            setTabState(lastTab != "texts")
            photosTab.setOnClickListener { setTabState(true) }
            textsTab.setOnClickListener { setTabState(false) }

            root.setOnClickListener {
                removeGalleryOverlay()
                showOverlay(lastImagePath)
            }

            closeBtn.setOnClickListener {
                removeGalleryOverlay()
                showOverlay(lastImagePath)
            }

            selectionClear.setOnClickListener {
                selectedImagePaths.clear()
                updateSelectionUi()
                (gridView.adapter as BaseAdapter).notifyDataSetChanged()
            }

            selectionSend.setOnClickListener {
                val selected = selectedImagePaths.toList()
                if (selected.isNotEmpty()) {
                    shareImagesToDiscord(selected)
                }
            }

            val params = WindowManager.LayoutParams()
            params.type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            } else {
                @Suppress("DEPRECATION")
                WindowManager.LayoutParams.TYPE_PHONE
            }
            params.format = android.graphics.PixelFormat.RGBA_8888
            params.width = WindowManager.LayoutParams.MATCH_PARENT
            params.height = WindowManager.LayoutParams.MATCH_PARENT
            params.gravity = Gravity.TOP or Gravity.START
            params.flags = WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS

            windowManager?.addView(galleryView, params)
        } catch (e: Exception) {
            galleryView = null
        }
    }

    private fun removeGalleryOverlay() {
        try {
            if (galleryView != null && windowManager != null) {
                windowManager?.removeView(galleryView)
                galleryView = null
            }
        } catch (e: Exception) {
            galleryView = null
        }
    }


    private fun loadFolderNames(key: String, orderKey: String): List<String> {
        val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val names = mutableListOf<String>()
        val raw = prefs.all[key]
        if (raw is String) {
            try {
                val json = JSONObject(raw)
                val iter = json.keys()
                while (iter.hasNext()) {
                    val name = iter.next()
                    if (name.isNotEmpty()) {
                        names.add(if (name == "기본") RECENT_FOLDER_NAME else name)
                    }
                }
            } catch (e: Exception) {
                // Ignore malformed values
            }
        }
        val uniqueNames = names.distinct()
        names.clear()
        names.addAll(uniqueNames)
        if (!names.contains(RECENT_FOLDER_NAME)) {
            names.add(RECENT_FOLDER_NAME)
        }
        val order = readStringListFromPrefs(prefs, orderKey)
        val normalizedOrder = order.map { if (it == "기본") RECENT_FOLDER_NAME else it }
        if (normalizedOrder.isNotEmpty()) {
            val ordered = normalizedOrder.filter { names.contains(it) }.distinct().toMutableList()
            for (name in names) {
                if (!ordered.contains(name)) {
                    ordered.add(name)
                }
            }
            ordered.remove(RECENT_FOLDER_NAME)
            ordered.add(0, RECENT_FOLDER_NAME)
            return ordered
        }
        names.sort()
        names.remove(RECENT_FOLDER_NAME)
        names.add(0, RECENT_FOLDER_NAME)
        return names
    }

    private fun loadImagePathsForFolder(folderName: String): List<String> {
        if (folderName.isEmpty()) return emptyList()
        val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val items = readFolderItems(prefs, "flutter.image_folders", folderName)
        return items
    }

    private fun loadTextItemsForFolder(folderName: String): List<String> {
        if (folderName.isEmpty()) return emptyList()
        val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val items = readFolderItems(prefs, "flutter.text_folders", folderName)
        return items
    }


    private fun readFolderItems(
        prefs: SharedPreferences,
        key: String,
        folderName: String
    ): List<String> {
        val result = mutableListOf<String>()
        val raw = prefs.all[key]
        if (raw is String) {
            try {
                val json = JSONObject(raw)
                val array = json.optJSONArray(folderName)
                    ?: if (folderName == RECENT_FOLDER_NAME) json.optJSONArray("기본") else null
                    ?: JSONArray()
                for (i in 0 until array.length()) {
                    val item = array.optString(i)
                    if (!item.isNullOrEmpty()) {
                        result.add(item)
                    }
                }
            } catch (e: Exception) {
                // Ignore malformed values
            }
        }
        return result
    }

    private fun readStringListFromPrefs(
        prefs: SharedPreferences,
        key: String
    ): List<String> {
        val result = mutableListOf<String>()
        val value = prefs.all[key]
        when (value) {
            is Set<*> -> {
                for (item in value) {
                    val text = item?.toString()
                    if (!text.isNullOrEmpty()) {
                        result.add(text)
                    }
                }
            }
            is String -> {
                try {
                    val json = JSONArray(value)
                    for (i in 0 until json.length()) {
                        val text = json.optString(i)
                        if (!text.isNullOrEmpty()) {
                            result.add(text)
                        }
                    }
                } catch (e: Exception) {
                    // Ignore malformed values
                }
            }
        }
        return result
    }

    private fun recordRecentImages(paths: List<String>) {
        val validPaths = paths.filter { it.isNotEmpty() && File(it).exists() }
        if (validPaths.isEmpty()) return

        try {
            val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val folders = readFolderJson(prefs, "flutter.image_folders")
            val existing = mutableListOf<String>()
            val currentRecent = folders.optJSONArray(RECENT_FOLDER_NAME)
                ?: folders.optJSONArray("기본")
                ?: JSONArray()
            for (i in 0 until currentRecent.length()) {
                val value = currentRecent.optString(i)
                if (!value.isNullOrEmpty() && !existing.contains(value)) {
                    existing.add(value)
                }
            }

            for (path in validPaths.asReversed()) {
                existing.remove(path)
                existing.add(0, path)
            }

            while (existing.size > RECENT_FOLDER_LIMIT) {
                existing.removeAt(existing.lastIndex)
            }

            val recentArray = JSONArray()
            for (item in existing) {
                recentArray.put(item)
            }
            folders.remove("기본")
            folders.put(RECENT_FOLDER_NAME, recentArray)

            val order = readStringListFromPrefs(prefs, "flutter.image_folder_order")
                .map { if (it == "기본") RECENT_FOLDER_NAME else it }
                .distinct()
                .toMutableList()
            val folderNames = folders.keys()
            while (folderNames.hasNext()) {
                val name = folderNames.next()
                if (name.isNotEmpty() && !order.contains(name)) {
                    order.add(name)
                }
            }
            order.remove(RECENT_FOLDER_NAME)
            order.add(0, RECENT_FOLDER_NAME)
            val orderArray = JSONArray()
            for (item in order) {
                orderArray.put(item)
            }

            prefs.edit()
                .putString("flutter.image_folders", folders.toString())
                .putString("flutter.image_folder_order", orderArray.toString())
                .apply()
        } catch (e: Exception) {
            // Ignore recent-list failures; sharing should still proceed.
        }
    }

    private fun readFolderJson(prefs: SharedPreferences, key: String): JSONObject {
        val raw = prefs.all[key]
        if (raw is String) {
            try {
                return JSONObject(raw)
            } catch (e: Exception) {
                // Ignore malformed values
            }
        }
        return JSONObject()
    }


    private fun shareImageToDiscord(path: String) {
        try {
            val file = File(path)
            if (!file.exists()) {
                Toast.makeText(this, "사진을 찾을 수 없습니다", Toast.LENGTH_SHORT).show()
                return
            }
            val discordPackage = resolveDiscordPackage()
            if (discordPackage == null) {
                Toast.makeText(this, "디스코드가 설치되어 있지 않습니다", Toast.LENGTH_SHORT).show()
                return
            }
            recordRecentImages(listOf(path))
            suppressOverlayForShare()
            val extension = extractExtension(file)
            val shareFile = prepareShareCacheFile(file, extension)
            val uri = FileProvider.getUriForFile(this, "${packageName}.fileprovider", shareFile)
            val mimeType = resolveMimeType(extension) ?: "image/*"
            val shareIntent = Intent(Intent.ACTION_SEND).apply {
                type = mimeType
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                setPackage(discordPackage)
            }
            grantUriPermission(discordPackage, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            startActivity(shareIntent)
        } catch (e: Exception) {
            Toast.makeText(this, "디스코드 공유에 실패했습니다", Toast.LENGTH_SHORT).show()
        }
    }

    private fun shareImagesToDiscord(paths: List<String>) {
        try {
            val files = paths.map { File(it) }.filter { it.exists() }
            if (files.isEmpty()) {
                Toast.makeText(this, "사진을 찾을 수 없습니다", Toast.LENGTH_SHORT).show()
                return
            }
            val discordPackage = resolveDiscordPackage()
            if (discordPackage == null) {
                Toast.makeText(this, "디스코드가 설치되어 있지 않습니다", Toast.LENGTH_SHORT).show()
                return
            }

            recordRecentImages(files.map { it.absolutePath })
            suppressOverlayForShare()
            val uris = ArrayList<Uri>()
            for (file in files) {
                val shareFile = prepareShareCacheFile(file, extractExtension(file))
                val uri = FileProvider.getUriForFile(this, "${packageName}.fileprovider", shareFile)
                uris.add(uri)
                grantUriPermission(discordPackage, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }

            val action = if (uris.size == 1) Intent.ACTION_SEND else Intent.ACTION_SEND_MULTIPLE
            val shareIntent = Intent(action).apply {
                type = "image/*"
                if (uris.size == 1) {
                    putExtra(Intent.EXTRA_STREAM, uris.first())
                } else {
                    putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
                }
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                setPackage(discordPackage)
            }
            startActivity(shareIntent)
        } catch (e: Exception) {
            Toast.makeText(this, "디스코드 공유에 실패했습니다", Toast.LENGTH_SHORT).show()
        }
    }

    private fun prepareShareCacheFile(source: File, extension: String): File {
        val shareDir = File(cacheDir, "shared_images")
        if (!shareDir.exists()) {
            shareDir.mkdirs()
        }
        val timestamp = System.currentTimeMillis()
        val safeExt = if (extension.isNotEmpty()) extension else ".jpg"
        var target = File(shareDir, "share_img_$timestamp$safeExt")
        var suffix = 1
        while (target.exists()) {
            target = File(shareDir, "share_img_${timestamp}_$suffix$safeExt")
            suffix += 1
        }
        source.copyTo(target, overwrite = false)
        return target
    }

    private fun extractExtension(file: File): String {
        val name = file.name
        val dot = name.lastIndexOf('.')
        if (dot <= 0 || dot >= name.length - 1) return ""
        return name.substring(dot).lowercase()
    }

    private fun resolveMimeType(extension: String): String? {
        val clean = extension.trimStart('.').lowercase()
        if (clean.isEmpty()) return null
        return android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(clean)
    }

    private fun shareTextToDiscord(text: String) {
        try {
            if (text.isEmpty()) {
                Toast.makeText(this, "텍스트가 비어 있습니다", Toast.LENGTH_SHORT).show()
                return
            }
            val discordPackage = resolveDiscordPackage()
            if (discordPackage == null) {
                Toast.makeText(this, "디스코드가 설치되어 있지 않습니다", Toast.LENGTH_SHORT).show()
                return
            }
            suppressOverlayForShare()
            val shareIntent = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_TEXT, text)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                setPackage(discordPackage)
            }
            startActivity(shareIntent)
        } catch (e: Exception) {
            Toast.makeText(this, "디스코드 공유에 실패했습니다", Toast.LENGTH_SHORT).show()
        }
    }

    private fun resolveDiscordPackage(): String? {
        val candidates = listOf("com.discord", "com.discord.android")
        for (name in candidates) {
            val exists = try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    packageManager.getPackageInfo(name, PackageManager.PackageInfoFlags.of(0))
                } else {
                    @Suppress("DEPRECATION")
                    packageManager.getPackageInfo(name, 0)
                }
                true
            } catch (e: Exception) {
                false
            }
            if (exists) return name
        }
        return null
    }

    private fun suppressOverlayForShare() {
        removeGalleryOverlay()
        removeOverlay()
        try {
            val intent = Intent(this, ForegroundAppMonitorService::class.java)
            intent.action = ForegroundAppMonitorService.ACTION_SUPPRESS_OVERLAY
            intent.putExtra(ForegroundAppMonitorService.EXTRA_SUPPRESS_MS, 2000L)
            startService(intent)
        } catch (e: Exception) {
            // Silently handle errors
        }
    }

    private fun openHostApp() {
        try {
            val launchIntent = packageManager.getLaunchIntentForPackage(packageName) ?: return
            launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(launchIntent)
        } catch (e: Exception) {
            Toast.makeText(this, "앱을 열 수 없습니다", Toast.LENGTH_SHORT).show()
        }
    }

    private fun showOverlay(imagePath: String?) {
        try {
            if (overlayView != null) {
                return
            }

            lastImagePath = imagePath
            
            ensureForeground()
            if (!isOverlayButtonEnabled()) {
                removeOverlay()
                return
            }
            windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
            val inflater = getSystemService(Context.LAYOUT_INFLATER_SERVICE) as LayoutInflater
            overlayView = inflater.inflate(R.layout.overlay_layout, null)

            val params = WindowManager.LayoutParams()
            params.type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            } else {
                @Suppress("DEPRECATION")
                WindowManager.LayoutParams.TYPE_PHONE
            }
            params.format = android.graphics.PixelFormat.RGBA_8888
            
            val scale = resources.displayMetrics.density
            val sizePx = getOverlaySizePx()
            val marginPx = (8 * scale).toInt()
            params.width = sizePx
            params.height = sizePx
            params.gravity = Gravity.TOP or Gravity.START
            if (overlayParams == null) {
                val saved = readOverlayPosition()
                if (saved != null) {
                    val (clampedX, clampedY) = clampOverlayPosition(
                        saved.first,
                        saved.second,
                        sizePx
                    )
                    params.x = clampedX
                    params.y = clampedY
                } else {
                    val dm = resources.displayMetrics
                    params.x = dm.widthPixels - sizePx - marginPx
                    params.y = (dm.heightPixels / 2) - (sizePx / 2)
                }
            } else {
                val (clampedX, clampedY) = clampOverlayPosition(
                    overlayParams?.x ?: 0,
                    overlayParams?.y ?: 0,
                    sizePx
                )
                params.x = clampedX
                params.y = clampedY
            }
            params.flags = WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL
            overlayParams = params

            val imageView = overlayView!!.findViewById<ImageView>(R.id.overlay_image)

            // Always show overlay icon
            imageView.visibility = android.view.View.VISIBLE
            applyOverlayIcon(imageView)
            applyOverlayBorder(imageView)
            imageView.isClickable = true
            imageView.isFocusable = true
            imageView.setOnClickListener {
                showGalleryOverlay()
            }

            // Touch handling for drag + click
            imageView.setOnTouchListener { _, event ->
                when (event.action) {
                    MotionEvent.ACTION_DOWN -> {
                        touchStartX = event.rawX
                        touchStartY = event.rawY
                        viewStartX = overlayParams?.x ?: 0
                        viewStartY = overlayParams?.y ?: 0
                        isDragging = false
                        true
                    }
                    MotionEvent.ACTION_MOVE -> {
                        val dx = (event.rawX - touchStartX).toInt()
                        val dy = (event.rawY - touchStartY).toInt()
                        val moved = kotlin.math.abs(dx) > 4 || kotlin.math.abs(dy) > 4
                        isDragging = isDragging || moved
                        val size = if ((overlayParams?.width ?: 0) > 0) {
                            overlayParams?.width ?: sizePx
                        } else {
                            sizePx
                        }
                        val (clampedX, clampedY) = clampOverlayPosition(
                            viewStartX + dx,
                            viewStartY + dy,
                            size
                        )
                        overlayParams?.x = clampedX
                        overlayParams?.y = clampedY
                        if (overlayParams != null && overlayView != null) {
                            windowManager?.updateViewLayout(overlayView, overlayParams)
                        }
                        if (isDragging) {
                            showCloseTarget()
                            updateCloseTargetState(isOverCloseTarget())
                        }
                        true
                    }
                    MotionEvent.ACTION_UP -> {
                        if (!isDragging) {
                            imageView.performClick()
                        }
                        val shouldClose = isDragging && isOverCloseTarget()
                        hideCloseTarget()
                        if (shouldClose) {
                            overlayParams?.x = viewStartX
                            overlayParams?.y = viewStartY
                            stopSelf()
                        }
                        true
                    }
                    MotionEvent.ACTION_CANCEL -> {
                        hideCloseTarget()
                        false
                    }
                    else -> false
                }
            }

            windowManager?.addView(overlayView, params)
        } catch (e: Exception) {
            overlayView = null
        }
    }

    private fun applyOverlaySettings() {
        try {
            if (!isOverlayButtonEnabled()) {
                val wasVisible = overlayView != null || galleryView != null
                removeOverlay()
                if (wasVisible) {
                    ensureForeground()
                }
                return
            }
            if (overlayView == null) {
                return
            }
            val imageView = overlayView?.findViewById<ImageView>(R.id.overlay_image)
            if (imageView != null) {
                applyOverlayIcon(imageView)
                applyOverlayBorder(imageView)
            }
            if (overlayView != null && overlayParams != null) {
                val sizePx = getOverlaySizePx()
                overlayParams?.width = sizePx
                overlayParams?.height = sizePx
                val (clampedX, clampedY) = clampOverlayPosition(
                    overlayParams?.x ?: 0,
                    overlayParams?.y ?: 0,
                    sizePx
                )
                overlayParams?.x = clampedX
                overlayParams?.y = clampedY
                windowManager?.updateViewLayout(overlayView, overlayParams)
            }
        } catch (e: Exception) {
            // Silently handle errors
        }
    }

    private fun isOverlayButtonEnabled(): Boolean {
        return getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .getBoolean("flutter.overlay_button_enabled", true)
    }

    private fun getOverlaySizePx(): Int {
        val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val value = prefs.all["flutter.overlay_size_dp"]
        val sizeDp = when (value) {
            is Float -> value.toDouble()
            is Double -> value
            is String -> value.toDoubleOrNull()
            else -> null
        } ?: 72.0
        val scale = resources.displayMetrics.density
        return (sizeDp * scale).toInt()
    }

    private fun getOverlayBorderPx(): Int {
        val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val value = prefs.all["flutter.overlay_border_dp"]
        val borderDp = when (value) {
            is Float -> value.toDouble()
            is Double -> value
            is String -> value.toDoubleOrNull()
            else -> null
        } ?: 10.0
        val scale = resources.displayMetrics.density
        return (borderDp * scale).toInt()
    }

    private fun getOverlayThumbPx(): Int {
        val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val value = prefs.all["flutter.overlay_thumb_dp"]
        val thumbDp = when (value) {
            is Float -> value.toDouble()
            is Double -> value
            is String -> value.toDoubleOrNull()
            else -> null
        } ?: 64.0
        val scale = resources.displayMetrics.density
        return (thumbDp * scale).toInt()
    }

    private fun clampOverlayPosition(x: Int, y: Int, sizePx: Int): Pair<Int, Int> {
        val dm = resources.displayMetrics
        val half = sizePx / 2
        val minX = -half
        val maxX = dm.widthPixels - half
        val minY = -half
        val maxY = dm.heightPixels - half
        return Pair(x.coerceIn(minX, maxX), y.coerceIn(minY, maxY))
    }

    private fun readOverlayPosition(): Pair<Int, Int>? {
        return try {
            val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val rawX = prefs.all["flutter.overlay_x"]
            val rawY = prefs.all["flutter.overlay_y"]
            val x = when (rawX) {
                is Int -> rawX
                is Float -> rawX.toInt()
                is Double -> rawX.toInt()
                is String -> rawX.toIntOrNull()
                else -> null
            }
            val y = when (rawY) {
                is Int -> rawY
                is Float -> rawY.toInt()
                is Double -> rawY.toInt()
                is String -> rawY.toIntOrNull()
                else -> null
            }
            if (x != null && y != null) Pair(x, y) else null
        } catch (e: Exception) {
            null
        }
    }

    private fun persistOverlayPosition() {
        try {
            val params = overlayParams ?: return
            val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            prefs.edit()
                .putInt("flutter.overlay_x", params.x)
                .putInt("flutter.overlay_y", params.y)
                .apply()
        } catch (e: Exception) {
            // Silently handle errors
        }
    }

    private fun applyOverlayIcon(imageView: ImageView) {
        try {
            val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            clearImageView(imageView)
            val iconPath = prefs.getString("flutter.overlay_icon_path", null)
            if (!iconPath.isNullOrEmpty()) {
                val iconFile = File(iconPath)
                if (iconFile.exists() && loadAnimatedGifIntoView(imageView, iconFile)) {
                    return
                }
            }
            val bmp = loadOverlayBitmap(prefs)
            if (bmp != null) {
                val rounded = RoundedBitmapDrawableFactory.create(resources, bmp)
                rounded.isCircular = true
                imageView.setImageDrawable(rounded)
                imageView.scaleType = ImageView.ScaleType.CENTER_CROP
                return
            }
            imageView.setImageResource(R.mipmap.ic_launcher)
        } catch (e: Exception) {
            imageView.setImageResource(R.mipmap.ic_launcher)
        }
    }

    private fun applyOverlayBorder(imageView: ImageView) {
        val padding = getOverlayBorderPx()
        imageView.setPadding(padding, padding, padding, padding)
    }

    private fun loadImageIntoView(
        imageView: ImageView,
        file: File,
        reqWidth: Int,
        reqHeight: Int
    ): Boolean {
        clearImageView(imageView)
        imageView.setBackgroundColor(Color.TRANSPARENT)

        if (loadAnimatedGifIntoView(imageView, file)) {
            return true
        }

        val bmp = decodeSampledBitmap(file.absolutePath, reqWidth, reqHeight)
        return if (bmp != null) {
            imageView.setImageBitmap(bmp)
            imageView.scaleType = ImageView.ScaleType.CENTER_CROP
            true
        } else {
            false
        }
    }

    private fun loadAnimatedGifIntoView(imageView: ImageView, file: File): Boolean {
        if (extractExtension(file) != ".gif") {
            return false
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
            loadImageDecoderGifIntoView(imageView, file)) {
            return true
        }

        return loadMovieGifIntoView(imageView, file)
    }

    private fun loadImageDecoderGifIntoView(imageView: ImageView, file: File): Boolean {
        return try {
            val source = ImageDecoder.createSource(file)
            val drawable = ImageDecoder.decodeDrawable(source)
            imageView.setImageDrawable(drawable)
            imageView.scaleType = ImageView.ScaleType.CENTER_CROP
            if (drawable is AnimatedImageDrawable) {
                drawable.repeatCount = AnimatedImageDrawable.REPEAT_INFINITE
                drawable.start()
            }
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun loadMovieGifIntoView(imageView: ImageView, file: File): Boolean {
        return try {
            val drawable = MovieGifDrawable(file)
            imageView.setImageDrawable(drawable)
            imageView.scaleType = ImageView.ScaleType.CENTER_CROP
            drawable.start()
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun clearImageView(imageView: ImageView) {
        val drawable = imageView.drawable
        if (drawable is Animatable) {
            drawable.stop()
        }
        imageView.setImageDrawable(null)
        imageView.setImageBitmap(null)
    }

    private fun decodeSampledBitmap(path: String, reqWidth: Int, reqHeight: Int): Bitmap? {
        val options = BitmapFactory.Options()
        options.inJustDecodeBounds = true
        BitmapFactory.decodeFile(path, options)

        options.inSampleSize = calculateInSampleSize(options, reqWidth, reqHeight)
        options.inPreferredConfig = Bitmap.Config.RGB_565
        options.inDither = true
        options.inJustDecodeBounds = false
        return BitmapFactory.decodeFile(path, options)
    }

    private fun calculateInSampleSize(
        options: BitmapFactory.Options,
        reqWidth: Int,
        reqHeight: Int
    ): Int {
        val (height, width) = options.run { outHeight to outWidth }
        var inSampleSize = 1

        if (height > reqHeight || width > reqWidth) {
            var halfHeight = height / 2
            var halfWidth = width / 2

            while (halfHeight / inSampleSize >= reqHeight &&
                halfWidth / inSampleSize >= reqWidth) {
                inSampleSize *= 2
            }
        }
        return inSampleSize
    }

    private fun loadOverlayBitmap(prefs: SharedPreferences): Bitmap? {
        val path = prefs.getString("flutter.overlay_icon_path", null)
        if (!path.isNullOrEmpty()) {
            val file = File(path)
            if (file.exists()) {
                return BitmapFactory.decodeFile(file.absolutePath)
            }
        }
        return BitmapFactory.decodeResource(resources, R.mipmap.ic_launcher)
    }

    private fun removeOverlay() {
        try {
            if (overlayView != null && windowManager != null) {
                persistOverlayPosition()
                windowManager?.removeView(overlayView)
                overlayView = null
            }
            hideCloseTarget()
        } catch (e: Exception) {
            overlayView = null
            hideCloseTarget()
        }
    }

    private fun ensureForeground() {
        val pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE
            } else {
                0
            }
        val addIntent = PendingIntent.getService(
            this,
            1201,
            Intent(this, OverlayService::class.java).apply { action = ACTION_OPEN_APP },
            pendingFlags
        )
        val sendIntent = PendingIntent.getService(
            this,
            1202,
            Intent(this, OverlayService::class.java).apply { action = ACTION_OPEN_GALLERY },
            pendingFlags
        )

        SideCordNotificationFactory.ensureChannel(this)
        val notification = SideCordNotificationFactory.build(
            context = this,
            addIntent = addIntent,
            sendIntent = sendIntent
        )

        notification.flags = notification.flags or
            Notification.FLAG_ONGOING_EVENT or
            Notification.FLAG_NO_CLEAR

        startForeground(SideCordNotificationFactory.NOTIFICATION_ID, notification)
    }

    private fun showCloseTarget() {
        if (closeTargetView != null) return
        if (windowManager == null) {
            windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        }
        val scale = resources.displayMetrics.density
        closeTargetSizePx = getOverlaySizePx()

        val container = FrameLayout(this)
        val bg = GradientDrawable()
        bg.shape = GradientDrawable.OVAL
        bg.setColor(Color.argb(220, 220, 0, 0))
        container.background = bg
        container.alpha = 0.7f

        val iconSize = (closeTargetSizePx * 0.4f).toInt().coerceAtLeast((20 * scale).toInt())
        val icon = ImageView(this)
        icon.setImageResource(android.R.drawable.ic_menu_close_clear_cancel)
        icon.setColorFilter(Color.WHITE)
        val iconParams = FrameLayout.LayoutParams(iconSize, iconSize, Gravity.CENTER)
        container.addView(icon, iconParams)

        val params = WindowManager.LayoutParams()
        params.type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }
        params.format = android.graphics.PixelFormat.RGBA_8888
        params.width = closeTargetSizePx
        params.height = closeTargetSizePx
        params.gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
        params.y = (96 * scale).toInt()
        params.flags = WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
            WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE

        closeTargetParams = params
        closeTargetView = container
        windowManager?.addView(container, params)
    }

    private fun hideCloseTarget() {
        try {
            if (closeTargetView != null && windowManager != null) {
                windowManager?.removeView(closeTargetView)
            }
        } catch (e: Exception) {
            // Silently handle errors
        } finally {
            closeTargetView = null
            closeTargetParams = null
            isOverCloseTarget = false
        }
    }

    private fun updateCloseTargetState(over: Boolean) {
        if (isOverCloseTarget == over) return
        isOverCloseTarget = over
        closeTargetView?.alpha = if (over) 1.0f else 0.7f
    }

    private fun isOverCloseTarget(): Boolean {
        val closeParams = closeTargetParams ?: return false
        if (closeTargetSizePx <= 0) return false
        val overlay = overlayParams ?: return false
        val overlaySize = if (overlay.width > 0) overlay.width else getOverlaySizePx()
        val overlayCenterX = overlay.x + (overlaySize / 2)
        val overlayCenterY = overlay.y + (overlaySize / 2)

        val dm = resources.displayMetrics
        val closeLeft = (dm.widthPixels - closeTargetSizePx) / 2 + closeParams.x
        val closeTop = dm.heightPixels - closeTargetSizePx - closeParams.y
        val closeCenterX = closeLeft + (closeTargetSizePx / 2)
        val closeCenterY = closeTop + (closeTargetSizePx / 2)

        val dx = (overlayCenterX - closeCenterX).toDouble()
        val dy = (overlayCenterY - closeCenterY).toDouble()
        val radius = (closeTargetSizePx / 2.0)
        return (dx * dx + dy * dy) <= (radius * radius)
    }
}
