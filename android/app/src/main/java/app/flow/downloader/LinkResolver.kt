package app.flow.downloader

import java.net.HttpURLConnection
import java.net.URI
import java.net.URL

object LinkResolver {
    const val USER_AGENT = "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36"

    /** Only expand known Douyin links. Leave arbitrary media URLs to yt-dlp. */
    fun resolve(input: String, open: (String) -> HttpURLConnection = { URL(it).openConnection() as HttpURLConnection }): String {
        var current = Input.validate(input)
        if (!Input.isDouyin(current) || Input.videoId(current) != null) return current
        repeat(8) {
            check(!Thread.currentThread().isInterrupted) { "链接解析已取消" }
            val connection = open(current)
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 12_000; connection.readTimeout = 12_000
            connection.setRequestProperty("User-Agent", USER_AGENT)
            try {
                val status = connection.responseCode
                if (status in listOf(301, 302, 303, 307, 308)) {
                    val location = connection.getHeaderField("Location") ?: error("抖音短链接缺少跳转地址。")
                    val next = URI(current).resolve(location).toString()
                    require(Input.isDouyin(next) && URI(next).scheme?.lowercase() in listOf("http", "https")) { "抖音短链接跳转到了无法识别的地址。" }
                    current = Input.canonicalize(next)
                    if (Input.videoId(current) != null) return current
                } else {
                    require(status in 200..299) { "抖音短链接访问失败（HTTP $status），请在官方网页中打开。" }
                    return current
                }
            } finally { connection.disconnect() }
        }
        error("抖音短链接跳转次数过多，请重新复制视频分享链接。")
    }
}
