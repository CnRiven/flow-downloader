package app.flow.downloader

import android.app.Application
import android.content.Context
import android.os.Handler
import android.os.Looper
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.ffmpeg.FFmpeg
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.locks.ReentrantReadWriteLock
import kotlin.concurrent.withLock

class FlowApplication : Application() {
    override fun onCreate() { super.onCreate(); Repo.init(this) }
}

data class Job(
    val id: String = UUID.randomUUID().toString(), val url: String, var title: String,
    val quality: Int, var status: String = "queued", var progress: Float = 0f,
    var detail: String = "", var contentUri: String = ""
) {
    fun json() = JSONObject().put("id", id).put("url", url).put("title", title).put("quality", quality)
        .put("status", status).put("progress", progress.toDouble()).put("detail", detail).put("contentUri", contentUri)
}

object Repo {
    private lateinit var context: Application
    private val jobs = mutableListOf<Job>()
    private val observers = mutableSetOf<() -> Unit>()
    private val main = Handler(Looper.getMainLooper())
    val metadataExecutor = Executors.newSingleThreadExecutor()
    @Volatile var engineReady = false
    @Volatile var engineError = ""
    @Volatile var activeJobId: String? = null
    @Volatile var engineVersion = ""
    private var lastPersist = 0L
    private val notificationPending = AtomicBoolean(false)
    private val engineLock = Any()
    private val engineAccess = ReentrantReadWriteLock(true)

    @Synchronized fun init(context: Application) {
        this.context = context
        val raw = context.getSharedPreferences("flow", 0).getString("jobs", "[]")!!
        runCatching {
            val array = JSONArray(raw)
            repeat(array.length()) {
                val j = array.getJSONObject(it)
                jobs += Job(j.getString("id"), j.getString("url"), j.getString("title"), j.getInt("quality").coerceIn(0, 3),
                    j.optString("status").let { if (it in listOf("queued", "downloading", "processing", "exporting")) "paused" else it },
                    j.optDouble("progress", 0.0).toFloat(), j.optString("detail"), j.optString("contentUri"))
            }
        }.onFailure {
            context.getSharedPreferences("flow", 0).edit().putString("corruptJobs", raw).apply()
            jobs.clear(); engineError = "历史记录读取失败，已保留原始数据。"
        }
        metadataExecutor.execute { runCatching { ensureEngine() }.onFailure { engineError = it.message ?: it.toString() }; notifyUI() }
    }
    fun ensureEngine() = synchronized(engineLock) {
        if (!engineReady) {
            BundledEngine.install(context)
            YoutubeDL.getInstance().init(context)
            FFmpeg.getInstance().init(context)
            engineVersion = BundledEngine.version(BundledEngine.file(context)) ?: BundledEngine.VERSION
            engineReady = true; engineError = ""
        }
    }
    fun <T> withEngine(action: () -> T): T = engineAccess.readLock().withLock { ensureEngine(); action() }
    fun updateEngine() = engineAccess.writeLock().withLock {
        ensureEngine()
        YoutubeDL.getInstance().updateYoutubeDL(context)
        engineVersion = BundledEngine.version(BundledEngine.file(context)) ?: engineVersion
    }
    @Synchronized fun snapshot() = jobs.map { it.copy() }
    @Synchronized fun get(id: String) = jobs.find { it.id == id }?.copy()
    @Synchronized fun next() = jobs.firstOrNull { it.status == "queued" }?.copy()
    @Synchronized fun add(job: Job) { jobs.add(0, job); persist(); notifyUI() }
    @Synchronized fun update(id: String, immediate: Boolean = true, change: (Job) -> Unit) {
        jobs.find { it.id == id }?.let(change)
        val now = System.currentTimeMillis()
        if (immediate || now - lastPersist > 1000) { persist(); lastPersist = now }
        notifyUI()
    }
    @Synchronized fun pauseActive() {
        jobs.filter { it.status in listOf("queued", "downloading", "processing", "exporting") }.forEach { it.status = "paused" }
        persist(); notifyUI()
    }
    @Synchronized fun remove(id: String) {
        jobs.removeAll { it.id == id }; persist(); notifyUI()
        if (activeJobId != id) java.io.File(context.getExternalFilesDir(null), "pending/$id").deleteRecursively()
    }
    @Synchronized fun observe(callback: () -> Unit) { observers += callback }
    @Synchronized fun unobserve(callback: () -> Unit) { observers -= callback }
    @Synchronized private fun persist() {
        context.getSharedPreferences("flow", 0).edit().putString("jobs", JSONArray(jobs.map { it.json() }).toString()).apply()
    }
    private fun notifyUI() {
        if (notificationPending.compareAndSet(false, true)) main.postDelayed({
            notificationPending.set(false)
            val callbacks = synchronized(this) { observers.toList() }; callbacks.forEach { it() }
        }, 150)
    }
}
