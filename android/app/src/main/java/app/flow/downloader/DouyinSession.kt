package app.flow.downloader

import android.content.Context
import android.webkit.CookieManager
import com.yausername.youtubedl_android.YoutubeDLRequest
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

data class BrowserVideo(val source: String, val url: String, val title: String, val userAgent: String, val savedAt: Long = System.currentTimeMillis())
data class PreparedRequest(val request: YoutubeDLRequest, val browserTitle: String? = null)

object DouyinSession {
    private val videos = mutableMapOf<String, BrowserVideo>()
    @Synchronized fun remember(video: BrowserVideo) { videos[Input.canonicalize(video.source)] = video }
    @Synchronized fun video(source: String): BrowserVideo? = videos[Input.canonicalize(source)]
        ?.takeIf { System.currentTimeMillis() - it.savedAt < 10 * 60 * 1000 }

    fun cookieFile(context: Context) = File(context.filesDir, "douyin-cookies.txt")

    /** Called only by the explicit 'use webpage state' action on the official website. */
    fun saveCookies(context: Context, userAgent: String) {
        val manager = CookieManager.getInstance()
        manager.flush()
        val lines = mutableListOf("# Netscape HTTP Cookie File")
        for ((url, domain) in listOf("https://www.douyin.com/" to ".douyin.com", "https://www.iesdouyin.com/" to ".iesdouyin.com")) {
            manager.getCookie(url)?.split(';')?.forEach { raw ->
                val fields = raw.trim().split('=', limit = 2)
                if (fields.size == 2 && fields[0].matches(Regex("[!#$%&'*+.^_`|~0-9A-Za-z-]+")) && fields[1].none { it == '\t' || it == '\r' || it == '\n' }) {
                    lines += "$domain\tTRUE\t/\tTRUE\t0\t${fields[0]}\t${fields[1]}"
                }
            }
        }
        val target = cookieFile(context)
        val temporary = File(context.filesDir, "douyin-cookies.tmp")
        temporary.writeText(lines.joinToString("\n", postfix = "\n"))
        java.nio.file.Files.move(temporary.toPath(), target.toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING, java.nio.file.StandardCopyOption.ATOMIC_MOVE)
        context.getSharedPreferences("flow", 0).edit().putString("douyinUserAgent", userAgent).apply()
    }

    fun prepare(context: Context, input: String, infoFile: File? = null): PreparedRequest {
        val source = LinkResolver.resolve(input)
        val douyin = Input.isDouyin(source)
        val captured = if (douyin) video(source) else null
        val request = if (captured != null && infoFile != null) {
            // Hand yt-dlp metadata for the video the user explicitly selected in the official player.
            val headers = JSONObject().put("User-Agent", captured.userAgent).put("Referer", captured.source)
            val format = JSONObject().put("format_id", "web").put("url", captured.url).put("ext", "mp4").put("http_headers", headers)
            val info = JSONObject().put("id", Input.videoId(source) ?: "douyin").put("title", captured.title)
                .put("webpage_url", source).put("extractor", "webpage").put("formats", JSONArray().put(format))
            infoFile.writeText(info.toString())
            YoutubeDLRequest(emptyList<String>()).apply { addOption("--load-info-json", infoFile.absolutePath) }
        } else YoutubeDLRequest(source)
        request.addOption("--ignore-config"); request.addOption("--no-playlist"); request.addOption("--playlist-items", "1")
        request.addOption("--socket-timeout", "25"); request.addOption("--retries", "2")
        if (douyin) {
            cookieFile(context).takeIf { it.isFile }?.let { request.addOption("--cookies", it.absolutePath) }
            request.addOption("--user-agent", captured?.userAgent ?: context.getSharedPreferences("flow", 0).getString("douyinUserAgent", LinkResolver.USER_AGENT)!!)
            request.addOption("--referer", source)
        }
        return PreparedRequest(request, captured?.title)
    }

    fun isVideoUrl(url: String): Boolean = runCatching {
        val uri = java.net.URI(url)
        val host = uri.host?.lowercase() ?: return@runCatching false
        uri.scheme == "https" && listOf("douyinvod.com", "bytecdn.cn", "bytecdn.com", "ibytedtos.com", "pstatp.com", "snssdk.com").any { host == it || host.endsWith(".$it") }
            && ((uri.path ?: "").contains("/video/") || (uri.path ?: "").endsWith(".mp4", true) || (uri.path ?: "").contains("/aweme/v1/play"))
    }.getOrDefault(false)
}
