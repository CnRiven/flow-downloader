package app.flow.downloader

object FailureMessage {
    fun message(raw: String): String = when {
        raw.contains("Fresh cookies", true) || raw.contains("cookies are needed", true) ->
            "抖音要求新的浏览器验证状态。请点击「抖音网页验证」，在官方页面完成验证或登录，再返回重试。也可以播放视频后选择「使用当前视频」。"
        raw.contains("Unsupported URL", true) && (raw.contains("douyin", true) || raw.contains("iesdouyin", true)) ->
            "这个抖音地址暂时无法直接解析。请打开「抖音网页验证」，播放目标视频后选择「使用当前视频」。"
        raw.contains("timed out", true) || raw.contains("timeout", true) -> "连接超时，请检查网络后重试。"
        else -> raw.lineSequence().lastOrNull { it.startsWith("ERROR:") }?.removePrefix("ERROR:")?.trim()
            ?: raw.take(800).ifBlank { "操作失败，请查看详细信息。" }
    }
}
