package app.flow.downloader

import android.content.Context
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.zip.ZipFile

object BundledEngine {
    const val VERSION = "2026.10.26"
    private const val SHA256 = "e51e69e89489f199530f13d32a4342da3ddb2cf34842f364603a066db05afbf3"

    fun file(context: Context) = File(context.noBackupFilesDir, "youtubedl-android/yt-dlp/yt-dlp")

    fun version(file: File): String? = runCatching {
        ZipFile(file).use { zip ->
            val entry = zip.getEntry("yt_dlp/version.py") ?: return@use null
            val text = zip.getInputStream(entry).bufferedReader().use { it.readText() }
            Regex("__version__\\s*=\\s*['\"]([^'\"]+)['\"]").find(text)?.groupValues?.get(1)
        }
    }.getOrNull()

    /** Upgrade existing installs as well as fresh installs; retain a newer user-updated engine. */
    fun install(context: Context) {
        val target = file(context)
        val installed = version(target)
        if (installed != null && installed >= VERSION) return
        target.parentFile!!.mkdirs()
        val temporary = File(target.parentFile, "yt-dlp.installing")
        try {
            context.resources.openRawResource(R.raw.ytdlp).use { source -> temporary.outputStream().use { source.copyTo(it) } }
            val digest = MessageDigest.getInstance("SHA-256")
            temporary.inputStream().use { input -> val buffer = ByteArray(64 * 1024); while (true) { val count = input.read(buffer); if (count < 0) break; digest.update(buffer, 0, count) } }
            check(digest.digest().joinToString("") { "%02x".format(it) } == SHA256) { "内置下载引擎校验失败，请重新安装完整的 APK。" }
            Files.move(temporary.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        } finally { temporary.delete() }
    }
}
