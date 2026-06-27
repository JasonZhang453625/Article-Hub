package com.passagesapp.passages_aggregation_app

import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "app.articlehub/backup"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "getInitialBackupFile") {
                result.success(getSharedFilePath(intent))
            } else {
                result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Forward the file path to Dart via a method channel or just store
        // it — the receive_sharing_intent plugin picks up ACTION_SEND natively.
        // For ACTION_VIEW we handle it.
    }

    private fun getSharedFilePath(intent: Intent?): String? {
        if (intent == null) return null

        return when (intent.action) {
            Intent.ACTION_VIEW -> {
                intent.data?.let { uri ->
                    copyToTemp(uri)
                }
            }
            Intent.ACTION_SEND -> {
                if (intent.type == "application/json") {
                    intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let { uri ->
                        copyToTemp(uri)
                    }
                } else {
                    null
                }
            }
            else -> null
        }
    }

    /// Copy a content:// URI to a temp file so Flutter can read it (File API
    /// cannot read content URIs directly).
    private fun copyToTemp(uri: Uri): String? {
        return try {
            val input = contentResolver.openInputStream(uri) ?: return null
            val temp = File.createTempFile("backup_import_", ".json", cacheDir)
            temp.outputStream().use { output -> input.copyTo(output) }
            input.close()
            temp.absolutePath
        } catch (e: Exception) {
            null
        }
    }
}
