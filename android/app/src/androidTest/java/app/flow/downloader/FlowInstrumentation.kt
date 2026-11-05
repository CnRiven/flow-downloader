package app.flow.downloader

import android.app.Activity
import android.app.Instrumentation
import android.os.Bundle
import com.yausername.youtubedl_android.YoutubeDL
import java.io.File
import java.security.MessageDigest

/** Exercises metadata captured from the official player without depending on a live site's verification. */
class FlowInstrumentation : Instrumentation() {
    private lateinit var arguments: Bundle
    override fun onCreate(arguments: Bundle?) { this.arguments = arguments ?: Bundle(); start() }
    override fun onStart() {
        Thread {
            val result = Bundle()
            val folder = File(targetContext.cacheDir, "captured-video-test").apply { mkdirs() }
            try {
                val url = arguments.getString("fixtureUrl") ?: error("Missing fixtureUrl")
                val digest = arguments.getString("fixtureSha256") ?: error("Missing fixtureSha256")
                val source = "https://www.douyin.com/video/7694479575518022946"
                DouyinSession.remember(BrowserVideo(source, url, "网页视频测试", LinkResolver.USER_AGENT))
                Repo.withEngine {
                    for (audio in listOf(false, true)) {
                        val prepared = DouyinSession.prepare(targetContext, source, File(folder, "info.json"))
                        check(prepared.browserTitle == "网页视频测试")
                        val request = prepared.request.apply {
                            addOption("--no-simulate"); addOption("--no-colors"); addOption("-f", "best")
                            addOption("-o", File(folder, if (audio) "audio.%(ext)s" else "video.%(ext)s").absolutePath)
                            if (audio) { addOption("-x"); addOption("--audio-format", "mp3") }
                        }
                        YoutubeDL.getInstance().execute(request, "captured-test", true)
                        val file = File(folder, if (audio) "audio.mp3" else "video.mp4")
                        check(file.isFile && file.length() > 0)
                        if (!audio) {
                            val actual = MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it) }
                            check(actual == digest) { "Captured-video download differs from original bytes" }
                        }
                    }
                }
                result.putString("stream", "PASS captured webpage metadata -> native yt-dlp video and MP3 download\n")
                finish(Activity.RESULT_OK, result)
            } catch (error: Throwable) {
                result.putString("stream", error.stackTraceToString()); finish(Activity.RESULT_CANCELED, result)
            } finally { folder.deleteRecursively() }
        }.start()
    }
}
