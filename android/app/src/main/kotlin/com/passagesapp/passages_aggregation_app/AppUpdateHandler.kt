package com.passagesapp.passages_aggregation_app

import android.app.Activity
import android.app.DownloadManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

class AppUpdateHandler(private val activity: Activity) {
    private val downloadManager =
        activity.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
    private val downloadPreferences =
        activity.getSharedPreferences("memora-update-downloads", Context.MODE_PRIVATE)

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "enqueueDownload" -> enqueueDownload(call, result)
            "queryDownload" -> queryDownload(call, result)
            "cancelDownload" -> cancelDownload(call, result)
            "verifyUpdate" -> verifyUpdate(call, result)
            "canRequestPackageInstalls" -> result.success(canRequestPackageInstalls())
            "openInstallPermissionSettings" -> openInstallPermissionSettings(result)
            "installUpdate" -> installUpdate(call, result)
            else -> result.notImplemented()
        }
    }

    private fun enqueueDownload(call: MethodCall, result: MethodChannel.Result) {
        val rawUrl = call.argument<String>("url")
        val version = call.argument<String>("version")
        val url = rawUrl?.let(Uri::parse)
        if (url == null || url.scheme != "https" || url.host.isNullOrBlank()) {
            result.error("INVALID_URL", "Update URL must use HTTPS", null)
            return
        }
        if (version == null || !VERSION_PATTERN.matches(version)) {
            result.error("INVALID_VERSION", "Invalid update version", null)
            return
        }

        val updateDirectory = managedUpdateDirectory()
        if (updateDirectory == null) {
            result.error("STORAGE_UNAVAILABLE", "Update storage is unavailable", null)
            return
        }
        updateDirectory.mkdirs()
        val destination = File(updateDirectory, "Memora-v$version.apk")
        if (destination.exists() && !destination.delete()) {
            result.error("DELETE_FAILED", "Could not replace the old update file", null)
            return
        }

        try {
            val request = DownloadManager.Request(url)
                .setTitle("Memora v$version")
                .setDescription("正在下载应用更新")
                .setMimeType(APK_MIME_TYPE)
                .setNotificationVisibility(
                    DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED,
                )
                .setAllowedOverMetered(true)
                .setAllowedOverRoaming(false)
                .setDestinationUri(Uri.fromFile(destination))
            val id = downloadManager.enqueue(request)
            downloadPreferences.edit().putString(id.toString(), destination.absolutePath).apply()
            result.success(mapOf("id" to id, "filePath" to destination.absolutePath))
        } catch (error: Exception) {
            result.error("DOWNLOAD_ENQUEUE_FAILED", error.message, null)
        }
    }

    private fun queryDownload(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<Number>("id")?.toLong()
        if (id == null) {
            result.error("INVALID_DOWNLOAD", "Missing download id", null)
            return
        }
        val query = DownloadManager.Query().setFilterById(id)
        try {
            downloadManager.query(query).use { cursor ->
                if (!cursor.moveToFirst()) {
                    result.success(
                        mapOf(
                            "status" to "failed",
                            "downloadedBytes" to 0L,
                            "totalBytes" to -1L,
                            "reason" to DownloadManager.ERROR_UNKNOWN,
                        ),
                    )
                    return
                }
                val status = cursor.getInt(
                    cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS),
                )
                val downloaded = cursor.getLong(
                    cursor.getColumnIndexOrThrow(
                        DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR,
                    ),
                )
                val total = cursor.getLong(
                    cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES),
                )
                val reason = cursor.getInt(
                    cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON),
                )
                result.success(
                    mapOf(
                        "status" to downloadStatusName(status),
                        "downloadedBytes" to downloaded,
                        "totalBytes" to total,
                        "reason" to reason,
                    ),
                )
            }
        } catch (error: Exception) {
            result.error("DOWNLOAD_QUERY_FAILED", error.message, null)
        }
    }

    private fun cancelDownload(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<Number>("id")?.toLong()
        if (id == null) {
            result.error("INVALID_DOWNLOAD", "Missing download id", null)
            return
        }
        downloadManager.remove(id)
        downloadPreferences.getString(id.toString(), null)?.let { path ->
            val file = File(path)
            if (isManagedUpdateFile(file)) file.delete()
        }
        downloadPreferences.edit().remove(id.toString()).apply()
        result.success(null)
    }

    private fun verifyUpdate(call: MethodCall, result: MethodChannel.Result) {
        val filePath = call.argument<String>("filePath")
        val expectedVersionCode = call.argument<Number>("expectedVersionCode")?.toLong()
        val expectedSize = call.argument<Number>("expectedSize")?.toLong()
        val expectedSha256 = call.argument<String>("expectedSha256")?.lowercase()
        if (filePath == null || expectedVersionCode == null || expectedSize == null ||
            expectedSha256 == null || !SHA256_PATTERN.matches(expectedSha256)
        ) {
            result.error("INVALID_VERIFICATION", "Invalid update verification values", null)
            return
        }

        Thread {
            try {
                val file = File(filePath)
                require(isManagedUpdateFile(file)) { "Update file is outside managed storage" }
                require(file.isFile) { "Downloaded APK is missing" }
                require(file.length() == expectedSize) { "APK file size does not match" }
                require(sha256(file) == expectedSha256) { "APK SHA-256 does not match" }

                val archiveInfo = packageArchiveInfo(file)
                    ?: error("Could not read APK package information")
                require(archiveInfo.packageName == activity.packageName) {
                    "APK package name does not match"
                }
                val archiveVersionCode = versionCode(archiveInfo)
                require(archiveVersionCode == expectedVersionCode) {
                    "APK versionCode does not match the manifest"
                }

                val installedInfo = installedPackageInfo()
                require(archiveVersionCode > versionCode(installedInfo)) {
                    "APK versionCode is not newer than the installed app"
                }
                require(signingDigests(archiveInfo) == signingDigests(installedInfo)) {
                    "APK signing certificate does not match"
                }
                activity.runOnUiThread { result.success(null) }
            } catch (error: Exception) {
                activity.runOnUiThread {
                    result.error("VERIFY_FAILED", error.message, null)
                }
            }
        }.start()
    }

    private fun canRequestPackageInstalls(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            activity.packageManager.canRequestPackageInstalls()
    }

    private fun openInstallPermissionSettings(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.success(null)
            return
        }
        try {
            val intent = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:${activity.packageName}"),
            )
            activity.startActivity(intent)
            result.success(null)
        } catch (error: Exception) {
            result.error("SETTINGS_FAILED", error.message, null)
        }
    }

    private fun installUpdate(call: MethodCall, result: MethodChannel.Result) {
        val filePath = call.argument<String>("filePath")
        if (filePath == null) {
            result.error("INVALID_INSTALL", "Missing update file", null)
            return
        }
        if (!canRequestPackageInstalls()) {
            result.error("INSTALL_PERMISSION_REQUIRED", "Install permission is required", null)
            return
        }

        Thread {
            var session: PackageInstaller.Session? = null
            try {
                val file = File(filePath)
                require(isManagedUpdateFile(file) && file.isFile) {
                    "Update file is invalid"
                }
                val installer = activity.packageManager.packageInstaller
                val parameters = PackageInstaller.SessionParams(
                    PackageInstaller.SessionParams.MODE_FULL_INSTALL,
                ).apply {
                    setAppPackageName(activity.packageName)
                    setSize(file.length())
                }
                val sessionId = installer.createSession(parameters)
                val openedSession = installer.openSession(sessionId)
                session = openedSession
                file.inputStream().use { input ->
                    openedSession.openWrite("base.apk", 0, file.length()).use { output ->
                        input.copyTo(output)
                        openedSession.fsync(output)
                    }
                }
                val statusIntent = Intent(activity, UpdateInstallReceiver::class.java).apply {
                    action = UpdateInstallReceiver.ACTION_INSTALL_STATUS
                }
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
                val pendingIntent = PendingIntent.getBroadcast(
                    activity,
                    sessionId,
                    statusIntent,
                    flags,
                )
                openedSession.commit(pendingIntent.intentSender)
                openedSession.close()
                session = null
                clearDownloadRecord(file)
                activity.runOnUiThread { result.success(null) }
            } catch (error: Exception) {
                session?.abandon()
                session?.close()
                activity.runOnUiThread {
                    result.error("INSTALL_FAILED", error.message, null)
                }
            }
        }.start()
    }

    private fun managedUpdateDirectory(): File? {
        val downloads = activity.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
            ?: return null
        return File(downloads, "updates")
    }

    private fun isManagedUpdateFile(file: File): Boolean {
        val directory = managedUpdateDirectory() ?: return false
        val rootPath = directory.canonicalFile.path + File.separator
        return file.canonicalFile.path.startsWith(rootPath)
    }

    private fun clearDownloadRecord(file: File) {
        val matchingEntry = downloadPreferences.all.entries.firstOrNull { entry ->
            entry.value == file.absolutePath
        }
        if (matchingEntry != null) {
            val downloadId = matchingEntry.key.toLongOrNull()
            if (downloadId != null) downloadManager.remove(downloadId)
            downloadPreferences.edit().remove(matchingEntry.key).apply()
        } else {
            file.delete()
        }
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { byte -> "%02x".format(byte) }
    }

    @Suppress("DEPRECATION")
    private fun packageArchiveInfo(file: File): PackageInfo? {
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            PackageManager.GET_SIGNATURES
        }
        return activity.packageManager.getPackageArchiveInfo(file.absolutePath, flags)
    }

    @Suppress("DEPRECATION")
    private fun installedPackageInfo(): PackageInfo {
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            PackageManager.GET_SIGNATURES
        }
        return activity.packageManager.getPackageInfo(activity.packageName, flags)
    }

    @Suppress("DEPRECATION")
    private fun versionCode(info: PackageInfo): Long {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            info.versionCode.toLong()
        }
    }

    @Suppress("DEPRECATION")
    private fun signingDigests(info: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val signingInfo = info.signingInfo ?: return emptySet()
            if (signingInfo.hasMultipleSigners()) {
                signingInfo.apkContentsSigners
            } else {
                signingInfo.signingCertificateHistory
            }
        } else {
            info.signatures ?: emptyArray()
        }
        return signatures.map { signature ->
            val digest = MessageDigest.getInstance("SHA-256").digest(signature.toByteArray())
            digest.joinToString("") { byte -> "%02x".format(byte) }
        }.toSet()
    }

    private fun downloadStatusName(status: Int): String {
        return when (status) {
            DownloadManager.STATUS_PENDING -> "pending"
            DownloadManager.STATUS_RUNNING -> "running"
            DownloadManager.STATUS_PAUSED -> "paused"
            DownloadManager.STATUS_SUCCESSFUL -> "successful"
            else -> "failed"
        }
    }

    companion object {
        private const val APK_MIME_TYPE = "application/vnd.android.package-archive"
        private val VERSION_PATTERN = Regex("^\\d+\\.\\d+\\.\\d+$")
        private val SHA256_PATTERN = Regex("^[a-f0-9]{64}$")
    }
}
