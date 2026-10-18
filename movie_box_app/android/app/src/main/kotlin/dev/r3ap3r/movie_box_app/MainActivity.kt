package dev.r3ap3r.movie_box_app

import android.content.ContentValues
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    private var pendingExport: (() -> Unit)? = null
    private var pendingExportResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.r3ap3r.movie_box_app/media")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "thumbnail" -> thumbnail(call, result)
                    "exportToDownloads" -> export(call, result)
                    "deleteSharedFile" -> deleteShared(call, result)
                    else -> result.notImplemented()
                }
            }
    }

    /** Rejects paths outside the app's own storage so no other file can be read. */
    private fun requireAppFile(path: String): File {
        val source = File(path).canonicalFile
        val appDirectory = filesDir.parentFile!!.canonicalFile
        if (!source.path.startsWith("${appDirectory.path}/") || !source.isFile) {
            throw IllegalArgumentException("File is not stored in this app")
        }
        return source
    }

    private fun thumbnail(call: MethodCall, result: MethodChannel.Result) {
        val path = call.arguments as? String
        if (path == null) {
            result.error("INVALID_PATH", "Video path is required", null)
            return
        }
        Thread {
            try {
                val source = requireAppFile(path)
                val destination = File("${source.path}.preview.jpg")
                if (!destination.exists()) {
                    val retriever = MediaMetadataRetriever()
                    try {
                        retriever.setDataSource(source.path)
                        val durationMs = retriever.extractMetadata(
                            MediaMetadataRetriever.METADATA_KEY_DURATION
                        )?.toLongOrNull() ?: 0L
                        val previewUs = if (durationMs > 0) durationMs * 250L else 120_000_000L
                        val frame = retriever.getFrameAtTime(
                            previewUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC
                        ) ?: throw IllegalStateException("No video frame available")
                        val width = 480
                        val height = (frame.height * width / frame.width).coerceAtLeast(1)
                        val scaled = Bitmap.createScaledBitmap(frame, width, height, true)
                        FileOutputStream(destination).use { scaled.compress(Bitmap.CompressFormat.JPEG, 82, it) }
                        if (scaled !== frame) scaled.recycle()
                        frame.recycle()
                    } finally {
                        retriever.release()
                    }
                }
                runOnUiThread { result.success(destination.path) }
            } catch (error: Exception) {
                runOnUiThread { result.error("THUMBNAIL_FAILED", error.message, null) }
            }
        }.start()
    }

    /**
     * Copies a finished download into the public Downloads folder, under
     * `movie-box/<title>/<episode>/`. The app keeps its own copy, so playback is
     * unaffected. Android 10 and later route this through MediaStore because
     * scoped storage forbids writing the path directly.
     */
    private fun export(call: MethodCall, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<*, *>
        val path = arguments?.get("path") as? String
        val relativePath = arguments?.get("relativePath") as? String
        val fileName = arguments?.get("fileName") as? String
        if (path == null || relativePath == null || fileName == null) {
            result.error("INVALID_ARGUMENTS", "path, relativePath and fileName are required", null)
            return
        }
        val subtitlePath = arguments?.get("subtitlePath") as? String
        val subtitleFileName = arguments?.get("subtitleFileName") as? String
        runExport(result, path, relativePath, fileName, subtitlePath, subtitleFileName)
    }

    private fun runExport(
        result: MethodChannel.Result,
        path: String,
        relativePath: String,
        fileName: String,
        subtitlePath: String?,
        subtitleFileName: String?,
    ) {
        val needsPermission = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
            checkSelfPermission(android.Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
            PackageManager.PERMISSION_GRANTED
        if (needsPermission) {
            pendingExport = {
                runExport(result, path, relativePath, fileName, subtitlePath, subtitleFileName)
            }
            pendingExportResult = result
            requestPermissions(
                arrayOf(android.Manifest.permission.WRITE_EXTERNAL_STORAGE),
                EXPORT_PERMISSION_REQUEST,
            )
            return
        }
        Thread {
            try {
                val video = writeShared(path, relativePath, fileName, "video/mp4")
                val hasSubtitle = subtitlePath != null && subtitleFileName != null &&
                    File(subtitlePath).isFile
                val subtitle = if (hasSubtitle) {
                    writeShared(subtitlePath!!, relativePath, subtitleFileName!!, "application/x-subrip")
                } else {
                    null
                }
                runOnUiThread {
                    result.success(
                        mapOf(
                            "video" to video,
                            "subtitle" to subtitle,
                        )
                    )
                }
            } catch (error: Exception) {
                runOnUiThread { result.error("EXPORT_FAILED", error.message, null) }
            }
        }.start()
    }

    private fun writeShared(
        sourcePath: String,
        relativePath: String,
        fileName: String,
        mimeType: String,
    ): String {
        val source = requireAppFile(sourcePath)
        val segments = relativePath.trim('/').split('/').filter { it.isNotBlank() }
        if (segments.isEmpty()) throw IllegalArgumentException("A relative path is required")
        val safeRelative = segments.joinToString("/")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = contentResolver
            val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            val target = "${Environment.DIRECTORY_DOWNLOADS}/$safeRelative"
            // Replace an earlier copy of the same episode instead of leaving " (1)" duplicates.
            resolver.delete(
                collection,
                "${MediaStore.MediaColumns.RELATIVE_PATH}=? AND ${MediaStore.MediaColumns.DISPLAY_NAME}=?",
                arrayOf("$target/", fileName),
            )
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                put(MediaStore.MediaColumns.RELATIVE_PATH, target)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = resolver.insert(collection, values)
                ?: throw IllegalStateException("Could not create $fileName in Downloads")
            try {
                val output = resolver.openOutputStream(uri)
                    ?: throw IllegalStateException("Could not write $fileName to Downloads")
                output.use { sink -> source.inputStream().use { it.copyTo(sink) } }
            } catch (error: Exception) {
                resolver.delete(uri, null, null)
                throw error
            }
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            return uri.toString()
        }
        val directory = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
            safeRelative,
        )
        if (!directory.isDirectory && !directory.mkdirs()) {
            throw IllegalStateException("Could not create ${directory.path}")
        }
        val destination = File(directory, fileName)
        if (destination.exists() && !destination.delete()) {
            throw IllegalStateException("Could not replace $fileName in Downloads")
        }
        source.inputStream().use { input ->
            FileOutputStream(destination).use { output -> input.copyTo(output) }
        }
        MediaScannerConnection.scanFile(this, arrayOf(destination.path), arrayOf(mimeType), null)
        return destination.path
    }

    private fun deleteShared(call: MethodCall, result: MethodChannel.Result) {
        val location = call.arguments as? String
        if (location.isNullOrBlank()) {
            result.success(null)
            return
        }
        Thread {
            try {
                if (location.startsWith("content://")) {
                    contentResolver.delete(Uri.parse(location), null, null)
                } else {
                    File(location).delete()
                }
                runOnUiThread { result.success(null) }
            } catch (error: Exception) {
                runOnUiThread { result.error("DELETE_FAILED", error.message, null) }
            }
        }.start()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != EXPORT_PERMISSION_REQUEST) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        val pending = pendingExport
        val result = pendingExportResult
        pendingExport = null
        pendingExportResult = null
        if (granted) {
            pending?.invoke()
        } else {
            result?.error(
                "PERMISSION_DENIED",
                "Storage permission is needed to save into Downloads on this Android version",
                null,
            )
        }
    }

    private companion object {
        const val EXPORT_PERMISSION_REQUEST = 4801
    }
}