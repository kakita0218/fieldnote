package jp.kakita0218.fieldnote.mobile

import android.app.Activity
import android.content.Intent
import android.net.Uri
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val channelName = "jp.fieldnote/android_storage"
    private val preferencesName = "fieldnote_android_storage"
    private val rootUriKey = "root_uri"
    private val projectUriPrefix = "project_uri_"
    private val directoryPickerRequestCode = 7401
    private val executor = Executors.newSingleThreadExecutor()
    private var pendingDirectoryResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasStorageAccess" -> result.success(hasStorageAccess())
                    "selectStorageDirectory" -> selectStorageDirectory(result)
                    "storageDirectoryName" ->
                        result.success(selectedRoot()?.name)
                    "syncProjectDirectory" -> {
                        val projectId = call.argument<String>("projectId")
                        val localPath = call.argument<String>("localPath")
                        if (projectId.isNullOrBlank() || localPath.isNullOrBlank()) {
                            result.error("invalid_arguments", "Project information is missing.", null)
                        } else {
                            runInBackground(result) {
                                syncProjectDirectory(projectId, File(localPath))
                            }
                        }
                    }
                    "deleteProjectDirectory" -> {
                        val projectId = call.argument<String>("projectId")
                        if (projectId.isNullOrBlank()) {
                            result.error("invalid_arguments", "Project ID is missing.", null)
                        } else {
                            runInBackground(result) { deleteProjectDirectory(projectId) }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun selectStorageDirectory(result: MethodChannel.Result) {
        if (pendingDirectoryResult != null) {
            result.error("picker_active", "The folder picker is already open.", null)
            return
        }
        pendingDirectoryResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
            )
            savedRootUri()?.let { putExtra("android.provider.extra.INITIAL_URI", it) }
        }
        startActivityForResult(intent, directoryPickerRequestCode)
    }

    @Deprecated("Required for the Storage Access Framework result callback")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != directoryPickerRequestCode) return
        val result = pendingDirectoryResult
        pendingDirectoryResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result?.success(false)
            return
        }
        try {
            contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
            val preferences = preferences()
            preferences.edit().apply {
                putString(rootUriKey, uri.toString())
                preferences.all.keys
                    .filter { it.startsWith(projectUriPrefix) }
                    .forEach { remove(it) }
                apply()
            }
            result?.success(true)
        } catch (error: Exception) {
            result?.error("storage_permission", error.message, null)
        }
    }

    private fun runInBackground(result: MethodChannel.Result, operation: () -> Unit) {
        executor.execute {
            try {
                operation()
                runOnUiThread { result.success(null) }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error("storage_operation", error.message, null)
                }
            }
        }
    }

    private fun preferences() = getSharedPreferences(preferencesName, MODE_PRIVATE)

    private fun savedRootUri(): Uri? =
        preferences().getString(rootUriKey, null)?.let(Uri::parse)

    private fun hasStorageAccess(): Boolean {
        val uri = savedRootUri() ?: return false
        val permission = contentResolver.persistedUriPermissions.firstOrNull {
            it.uri == uri && it.isReadPermission && it.isWritePermission
        } ?: return false
        val document = DocumentFile.fromTreeUri(this, permission.uri)
        return document?.exists() == true && document.canRead() && document.canWrite()
    }

    private fun selectedRoot(): DocumentFile? {
        if (!hasStorageAccess()) return null
        return savedRootUri()?.let { DocumentFile.fromTreeUri(this, it) }
    }

    private fun fieldNoteRoot(): DocumentFile {
        val selected = selectedRoot()
            ?: throw IllegalStateException("保存先フォルダへのアクセスがありません。")
        if (selected.name.equals("FieldNote", ignoreCase = true)) return selected
        return selected.findFile("FieldNote")
            ?: selected.createDirectory("FieldNote")
            ?: throw IllegalStateException("FieldNoteフォルダを作成できませんでした。")
    }

    private fun syncProjectDirectory(projectId: String, localDirectory: File) {
        require(localDirectory.isDirectory) { "案件フォルダが見つかりません。" }
        val root = fieldNoteRoot()
        val key = projectUriPrefix + projectId
        var target = preferences().getString(key, null)
            ?.let(Uri::parse)
            ?.let { DocumentFile.fromSingleUri(this, it) }
            ?.takeIf { it.exists() && it.isDirectory }

        if (target == null) {
            target = root.findFile(localDirectory.name)?.takeIf { it.isDirectory }
                ?: root.createDirectory(localDirectory.name)
        } else if (target.name != localDirectory.name) {
            if (!target.renameTo(localDirectory.name)) {
                target.delete()
                target = root.createDirectory(localDirectory.name)
            }
        }
        val projectTarget = target
            ?: throw IllegalStateException("案件フォルダを作成できませんでした。")
        syncDirectory(localDirectory, projectTarget)
        preferences().edit().putString(key, projectTarget.uri.toString()).apply()
    }

    private fun syncDirectory(source: File, destination: DocumentFile) {
        val sourceChildren = source.listFiles()?.toList().orEmpty()
            .filterNot {
                it.name.endsWith(".bak") ||
                    it.name.contains(".tmp-") ||
                    it.name.startsWith(".moving-") ||
                    it.name.startsWith(".fieldnote-")
            }
        val sourceNames = sourceChildren.map { it.name }.toSet()
        destination.listFiles()
            .filterNot { sourceNames.contains(it.name) }
            .forEach { it.delete() }

        for (child in sourceChildren) {
            if (child.isDirectory) {
                var target = destination.findFile(child.name)
                if (target != null && !target.isDirectory) {
                    target.delete()
                    target = null
                }
                val directory = target ?: destination.createDirectory(child.name)
                    ?: throw IllegalStateException("${child.name}フォルダを作成できませんでした。")
                syncDirectory(child, directory)
            } else {
                var target = destination.findFile(child.name)
                if (target != null && target.isDirectory) {
                    target.delete()
                    target = null
                }
                val canReusePhoto = target != null &&
                    child.extension.equals("jpg", ignoreCase = true) &&
                    target.length() == child.length()
                if (canReusePhoto) continue
                if (target == null) {
                    target = destination.createFile(mimeType(child), child.name)
                }
                target ?: throw IllegalStateException("${child.name}を作成できませんでした。")
                contentResolver.openOutputStream(target.uri, "rwt").use { output ->
                    requireNotNull(output) { "${child.name}を開けませんでした。" }
                    child.inputStream().use { input -> input.copyTo(output) }
                }
            }
        }
    }

    private fun mimeType(file: File): String = when (file.extension.lowercase()) {
        "pdf" -> "application/pdf"
        "jpg", "jpeg" -> "image/jpeg"
        "png" -> "image/png"
        "zip" -> "application/zip"
        "json" -> "application/json"
        else -> "application/octet-stream"
    }

    private fun deleteProjectDirectory(projectId: String) {
        val key = projectUriPrefix + projectId
        preferences().getString(key, null)
            ?.let(Uri::parse)
            ?.let { DocumentFile.fromSingleUri(this, it) }
            ?.takeIf { it.exists() }
            ?.delete()
        preferences().edit().remove(key).apply()
    }
}
