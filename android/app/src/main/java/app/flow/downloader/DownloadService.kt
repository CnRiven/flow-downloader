package app.flow.downloader

import android.app.*
import android.content.*
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.*
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class DownloadService : Service() {
    private val executor = Executors.newSingleThreadExecutor()
    private val draining = AtomicBoolean(false)
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var currentId: String? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var lastNotification = 0L
    @Volatile private var destroyed = false

    override fun onCreate() {
        super.onCreate()
        getSystemService(NotificationManager::class.java).createNotificationChannel(NotificationChannel("downloads", "下载进度", NotificationManager.IMPORTANCE_LOW))
        startForeground(1, notification("正在准备下载"), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        wakeLock = (getSystemService(POWER_SERVICE) as PowerManager).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "flow:download").apply { acquire(6 * 60 * 60 * 1000L) }
    }
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "pause") {
            val id = intent.getStringExtra("id") ?: return START_NOT_STICKY
            Repo.update(id) { it.status = "paused" }
            cancelWhenRegistered(id)
        }
        pump()
        return START_NOT_STICKY
    }
    private fun cancelWhenRegistered(id: String, attempts: Int = 0) {
        runCatching { YoutubeDL.getInstance().destroyProcessById(id) }
        if (attempts < 12 && currentId == id) main.postDelayed({ cancelWhenRegistered(id, attempts + 1) }, 250)
    }
    private fun pump() {
        if (!draining.compareAndSet(false, true)) return
        executor.execute {
            try {
                Repo.ensureEngine()
                while (!destroyed) {
                    val job = Repo.next() ?: break
                    currentId = job.id; Repo.activeJobId = job.id
                    runJob(job)
                    currentId = null; Repo.activeJobId = null
                }
            } catch (error: Exception) {
                Repo.next()?.let { job -> Repo.update(job.id) { it.status = "failed"; it.detail = error.message ?: error.toString() } }
            } finally {
                draining.set(false)
                main.post { if (!destroyed && Repo.next() != null) pump() else stopSelf() }
            }
        }
    }
    private fun runJob(job: Job) {
        val directory = File(getExternalFilesDir(null), "pending/${job.id}").apply { mkdirs() }
        var logTail = ""
        try {
            if (Repo.get(job.id)?.status != "queued") return
            Repo.update(job.id) { it.status = "downloading"; it.detail = "正在连接…" }
            val response = Repo.withEngine {
                val prepared = DouyinSession.prepare(this, job.url, File(directory, "web-video.json"))
                val request = prepared.request.apply {
                    addOption("--ignore-config"); addOption("--no-playlist"); addOption("--no-colors")
                    addOption("--playlist-items", "1")
                    addOption("--socket-timeout", "30"); addOption("--retries", "3")
                    addOption("--continue"); addOption("--no-overwrites"); addOption("--no-simulate")
                    addOption("--progress"); addOption("--newline")
                    addOption("--progress-template", "download:FLOW_PROGRESS:%(progress)j")
                    addOption("--print", "before_dl:FLOW_TITLE:%(title)j")
                    addOption("--print", "after_move:FLOW_FILE:%(filepath)j")
                    addOption("-o", File(directory, "%(title).160B [%(id)s].%(ext)s").absolutePath)
                    addOption("-f", if (prepared.browserTitle != null) "best" else Input.formats[job.quality])
                    if (job.quality == 3) { addOption("-x"); addOption("--audio-format", "mp3"); addOption("--audio-quality", "0") }
                    else addOption("--merge-output-format", "mp4/mkv")
                }
                if (Repo.get(job.id)?.status != "downloading") return@withEngine null
                YoutubeDL.getInstance().execute(request, job.id, true) { _, _, line ->
                    if (Repo.get(job.id)?.status == "paused" || destroyed) {
                        runCatching { YoutubeDL.getInstance().destroyProcessById(job.id) }
                    } else {
                        when {
                            line.startsWith("FLOW_PROGRESS:") -> runCatching {
                                val data = org.json.JSONObject(line.removePrefix("FLOW_PROGRESS:"))
                                val bytes = data.optDouble("downloaded_bytes", 0.0)
                                val total = data.optDouble("total_bytes", data.optDouble("total_bytes_estimate", 0.0))
                                val progress = if (total > 0) (bytes / total).toFloat().coerceIn(0f, 1f) else 0f
                                val finished = data.optString("status") == "finished"
                                Repo.update(job.id, false) {
                                    it.progress = progress; it.status = if (finished) "processing" else "downloading"
                                    it.detail = if (finished) "正在合并 / 转换" else "${(progress * 100).toInt()}% · 剩余 ${data.optLong("eta", 0).coerceAtLeast(0)} 秒"
                                }
                                updateNotification("${Repo.get(job.id)?.title ?: job.title} · ${(progress * 100).toInt()}%")
                            }
                            line.startsWith("FLOW_TITLE:") -> runCatching {
                                val title = org.json.JSONArray("[${line.removePrefix("FLOW_TITLE:")}]").getString(0)
                                Repo.update(job.id) { it.title = title }
                            }
                            else -> logTail = (logTail + "\n" + line).takeLast(6000)
                        }
                    }
                }
            } ?: return
            if (Repo.get(job.id) == null || Repo.get(job.id)?.status == "paused" || destroyed) return
            val output = response.out.lineSequence().lastOrNull { it.startsWith("FLOW_FILE:") }
                ?.removePrefix("FLOW_FILE:")?.let { org.json.JSONArray("[$it]").getString(0) }
            val file = output?.let { File(it) }?.takeIf { it.isFile && it.canonicalPath.startsWith(directory.canonicalPath + File.separator) }
                ?: throw IllegalStateException("未找到下载完成的文件。")
            Repo.update(job.id) { it.status = "exporting"; it.detail = "正在保存到系统下载目录…" }
            val uri = export(file)
            Repo.update(job.id) { it.status = "completed"; it.progress = 1f; it.contentUri = uri.toString(); it.title = file.nameWithoutExtension; it.detail = "已保存至 Download/拾流" }
            directory.deleteRecursively()
        } catch (error: Exception) {
            if (Repo.get(job.id)?.status != "paused" && !destroyed) Repo.update(job.id) { it.status = "failed"; it.detail = (error.message?.takeIf { message -> message.isNotBlank() } ?: logTail.ifBlank { error.toString() }).takeLast(4000) }
        } finally {
            if (Repo.get(job.id) == null) directory.deleteRecursively()
        }
    }
    private fun export(file: File): Uri {
        val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, file.name)
            put(MediaStore.Downloads.MIME_TYPE, MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension) ?: "application/octet-stream")
            put(MediaStore.Downloads.RELATIVE_PATH, "Download/拾流")
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = contentResolver.insert(collection, values) ?: error("无法创建输出文件")
        try {
            contentResolver.openOutputStream(uri)?.use { output -> file.inputStream().use { it.copyTo(output) } } ?: error("无法写入下载目录")
            contentResolver.update(uri, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
            return uri
        } catch (error: Exception) { contentResolver.delete(uri, null, null); throw error }
    }
    private fun notification(text: String): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return Notification.Builder(this, "downloads").setSmallIcon(android.R.drawable.stat_sys_download).setContentTitle("拾流 · 正在下载")
            .setContentText(text).setContentIntent(open).setOngoing(true).build()
    }
    private fun updateNotification(text: String) {
        val now = System.currentTimeMillis()
        if (now - lastNotification > 1000) { lastNotification = now; getSystemService(NotificationManager::class.java).notify(1, notification(text)) }
    }
    override fun onTimeout(startId: Int, fgsType: Int) { Repo.pauseActive(); currentId?.let { cancelWhenRegistered(it) }; stopSelf() }
    override fun onDestroy() {
        destroyed = true; Repo.pauseActive(); currentId?.let { runCatching { YoutubeDL.getInstance().destroyProcessById(it) } }
        executor.shutdownNow(); if (wakeLock?.isHeld == true) wakeLock?.release()
        super.onDestroy()
    }
}
