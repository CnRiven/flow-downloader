package app.flow.downloader

import java.net.URI

object Input {
    fun validate(input: String): String {
        val value = extract(input)
        val uri = runCatching { URI(value) }.getOrNull()
        require(uri != null && uri.scheme?.lowercase() in listOf("http", "https") && !uri.host.isNullOrBlank() && value.none { it.isWhitespace() }) {
            "请粘贴完整的 http:// 或 https:// 视频链接。"
        }
        return canonicalize(value)
    }

    fun extract(input: String): String {
        val text = input.trim().trim('\u200B', '\uFEFF')
        val candidate = Regex("https?://[^\\s<>\\\"“”‘’（）【】\\[\\]()，。；！、]+", RegexOption.IGNORE_CASE)
            .find(text)?.value ?: text
        return candidate.trimEnd('.', ',', ';', '!', '。', '，', '；', '！')
    }

    fun isDouyin(url: String): Boolean {
        val host = runCatching { URI(url).host?.lowercase() }.getOrNull() ?: return false
        return host == "douyin.com" || host.endsWith(".douyin.com") || host == "iesdouyin.com" || host.endsWith(".iesdouyin.com")
    }

    fun videoId(url: String): String? {
        if (!isDouyin(url)) return null
        val uri = URI(url)
        return Regex("/(?:share/|xg/)?video/(\\d+)(?:/|$)").find(uri.path ?: "")?.groupValues?.get(1)
            ?: Regex("(?:^|&)(?:modal_id|aweme_id|item_id)=(\\+?\\d+)(?:&|$)").find(uri.rawQuery ?: "")?.groupValues?.get(1)?.trimStart('+')
    }

    fun canonicalize(url: String): String = videoId(url)?.let { "https://www.douyin.com/video/$it" } ?: url

    val labels = listOf("最佳画质", "1080p", "720p", "仅音频 · MP3")
    val formats = listOf("bv*+ba/b", "bv*[height<=1080]+ba/b[height<=1080]", "bv*[height<=720]+ba/b[height<=720]", "bestaudio/best")
}
