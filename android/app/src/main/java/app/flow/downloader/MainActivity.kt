package app.flow.downloader

import android.Manifest
import android.app.*
import android.content.*
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.*
import android.view.*
import android.widget.*
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest

class MainActivity : Activity() {
    private val ink = Color.rgb(32, 50, 46)
    private val green = Color.rgb(36, 107, 82)
    private val mint = Color.rgb(220, 238, 225)
    private val paper = Color.rgb(247, 248, 244)
    private val muted = Color.rgb(120, 132, 125)
    private lateinit var input: EditText
    private lateinit var quality: Spinner
    private lateinit var preview: TextView
    private lateinit var tasks: LinearLayout
    private lateinit var summary: TextView
    private lateinit var parseButton: Button
    private var filter = "all"
    private var previewURL = ""
    private var previewTitle = ""
    private var inspectionGeneration = 0
    private val observer: () -> Unit = { renderJobs() }

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        window.statusBarColor = paper; window.navigationBarColor = paper
        window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR or View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR
        val outer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setBackgroundColor(paper) }
        outer.setOnApplyWindowInsetsListener { view, insets ->
            val bars = if (Build.VERSION.SDK_INT >= 30) insets.getInsets(WindowInsets.Type.systemBars()) else null
            if (bars != null) view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            insets
        }
        val scroll = ScrollView(this).apply { isFillViewport = true }
        val content = column().apply { setPadding(dp(24), dp(20), dp(24), dp(30)) }
        val brand = row()
        brand.addView(label("↓", 29, green, true).apply { gravity = Gravity.CENTER; background = shape(mint, 15) }, LinearLayout.LayoutParams(dp(48), dp(48)))
        brand.addView(column().apply {
            setPadding(dp(12), 0, 0, 0); addView(label("拾流", 24, ink, true)); addView(label("FLOW DOWNLOADER", 9, muted).apply { letterSpacing = 0.15f })
        }, LinearLayout.LayoutParams(0, -2, 1f))
        brand.addView(button("设置", false) { showSettings() })
        content.addView(brand); content.addView(space(28))
        content.addView(label("把喜欢的，\n留在设备里。", 30, ink, true).apply { setLineSpacing(dp(5).toFloat(), 1f) })
        content.addView(space(8)); content.addView(label("一段链接，收藏每一份灵感。", 13, muted))
        content.addView(space(25))
        val card = column().apply { background = shape(mint, 18); setPadding(dp(18), dp(20), dp(18), dp(20)) }
        card.addView(label("下一份灵感，从这里开始", 17, ink, true)); card.addView(space(14))
        input = EditText(this).apply {
            hint = "粘贴链接或整段抖音分享文案"; textSize = 13f; setSingleLine(); setTextColor(ink); setHintTextColor(muted)
            inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_URI
            background = shape(Color.WHITE, 10); setPadding(dp(13), dp(12), dp(13), dp(12))
        }
        card.addView(input, LinearLayout.LayoutParams(-1, dp(50))); card.addView(space(10))
        val actionRow = row()
        actionRow.addView(button("粘贴", false) {
            val clipboard = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
            clipboard.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(this)?.let { input.setText(Input.extract(it.toString())) }
        }, LinearLayout.LayoutParams(0, dp(45), 1f))
        actionRow.addView(space(10))
        parseButton = button("解析链接", true) { inspect() }
        actionRow.addView(parseButton, LinearLayout.LayoutParams(0, dp(45), 1f)); card.addView(actionRow)
        preview = label("支持 yt-dlp 可解析的站点 · 单视频下载", 11, green).apply { setPadding(0, dp(12), 0, dp(4)) }
        card.addView(preview); card.addView(space(8))
        card.addView(button("抖音网页验证 / 登录", false) { openDouyinBrowser() }, LinearLayout.LayoutParams(-1, dp(42)))
        card.addView(space(10))
        quality = Spinner(this).apply {
            adapter = ArrayAdapter(this@MainActivity, android.R.layout.simple_spinner_dropdown_item, Input.labels)
            setSelection(1); background = shape(Color.WHITE, 9)
        }
        card.addView(quality, LinearLayout.LayoutParams(-1, dp(46))); card.addView(space(12))
        card.addView(button("＋  加入下载队列", true) { enqueue() }, LinearLayout.LayoutParams(-1, dp(48)))
        content.addView(card); content.addView(space(24))
        summary = label("", 12, muted); content.addView(summary); content.addView(space(14))
        val tabs = row()
        listOf("全部" to "all", "下载中" to "active", "已完成" to "completed").forEach { (text, id) ->
            tabs.addView(button(text, false) { filter = id; renderJobs() }, LinearLayout.LayoutParams(0, dp(42), 1f))
        }
        content.addView(tabs); content.addView(space(15))
        tasks = column(); content.addView(tasks); content.addView(space(22))
        content.addView(label("本地下载  ·  自由收藏\n拾流 1.0.1 · Powered by yt-dlp", 10, muted).apply { gravity = Gravity.CENTER; setLineSpacing(dp(6).toFloat(), 1f) })
        scroll.addView(content); outer.addView(scroll); setContentView(outer)
        input.setText(state?.getString("input") ?: sharedURL(intent))
        state?.getInt("quality")?.let { quality.setSelection(it) }
        filter = state?.getString("filter") ?: "all"
        renderJobs()
    }
    override fun onSaveInstanceState(out: Bundle) {
        out.putString("input", input.text.toString()); out.putInt("quality", quality.selectedItemPosition); out.putString("filter", filter)
        super.onSaveInstanceState(out)
    }
    private fun sharedURL(intent: Intent): String {
        val text = if (intent.action == Intent.ACTION_SEND) intent.getStringExtra(Intent.EXTRA_TEXT) ?: "" else ""
        return Input.extract(text)
    }
    override fun onResume() { super.onResume(); Repo.observe(observer); renderJobs() }
    override fun onPause() { Repo.unobserve(observer); super.onPause() }
    override fun onDestroy() { inspectionGeneration++; super.onDestroy() }

    private fun inspect() {
        val url = runCatching { Input.validate(input.text.toString()) }.getOrElse { showError(it); return }
        val generation = ++inspectionGeneration
        parseButton.isEnabled = false; preview.text = "正在获取视频信息…"
        Repo.metadataExecutor.execute {
            val result = runCatching {
                Repo.withEngine {
                    val prepared = DouyinSession.prepare(this, url)
                    prepared.browserTitle ?: YoutubeDL.getInstance().getInfo(prepared.request).title ?: Uri.parse(url).host ?: url
                }
            }
            runOnUiThread {
                if (generation != inspectionGeneration || isDestroyed) return@runOnUiThread
                parseButton.isEnabled = true
                if (runCatching { Input.validate(input.text.toString()) }.getOrNull() != url) return@runOnUiThread
                result.onSuccess { title -> previewURL = url; previewTitle = title; preview.text = previewTitle }
                    .onFailure { preview.text = "解析失败，可以重试或直接添加下载。"; showError(it) }
            }
        }
    }
    private fun enqueue() {
        runCatching {
            val url = Input.validate(input.text.toString())
            val job = Job(url = url, title = if (url == previewURL) previewTitle else Uri.parse(url).host ?: url, quality = quality.selectedItemPosition)
            Repo.add(job)
            try { startForegroundService(Intent(this, DownloadService::class.java)) }
            catch (error: Exception) { Repo.update(job.id) { it.status = "failed"; it.detail = error.message ?: "无法启动下载服务" }; throw error }
            input.setText(""); preview.text = "已加入队列，下载可在后台继续。"
            if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }.onFailure { showError(it) }
    }
    private fun renderJobs() {
        if (!::tasks.isInitialized) return
        val all = Repo.snapshot()
        val active = listOf("queued", "downloading", "processing", "exporting", "paused")
        summary.text = getString(R.string.job_summary, all.count { it.status in active }, all.count { it.status == "completed" })
        tasks.removeAllViews()
        val filtered = all.filter { filter == "all" || (filter == "active" && it.status in active) || (filter == "completed" && it.status == "completed") }
        if (filtered.isEmpty()) {
            tasks.addView(column().apply {
                background = shape(Color.WHITE, 15); gravity = Gravity.CENTER; setPadding(dp(15), dp(35), dp(15), dp(35))
                addView(label("↓", 35, green)); addView(space(12)); addView(label("你的收藏，从第一段链接开始", 14, ink, true)); addView(space(8)); addView(label("粘贴上方链接，添加一个下载吧。", 11, muted))
            }); return
        }
        filtered.forEach { job ->
            val card = column().apply { background = shape(Color.WHITE, 14); setPadding(dp(17), dp(17), dp(17), dp(17)) }
            card.addView(label(job.title, 14, ink, true).apply { maxLines = 2; ellipsize = android.text.TextUtils.TruncateAt.END })
            card.addView(space(7)); card.addView(label("${Input.labels[job.quality]}  ·  ${status(job.status)}", 11, green))
            if (job.status in listOf("downloading", "processing", "exporting", "paused")) {
                card.addView(space(8)); card.addView(ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply { max = 100; progress = (job.progress * 100).toInt(); progressTintList = android.content.res.ColorStateList.valueOf(green) })
            }
            if (job.detail.isNotEmpty()) { card.addView(space(8)); card.addView(label(if (job.status == "failed") FailureMessage.message(job.detail) else job.detail.takeLast(200), 11, if (job.status == "failed") Color.rgb(170, 55, 55) else muted).apply { maxLines = 3 }) }
            card.addView(space(10)); val actions = row()
            if (job.status == "completed") actions.addView(button("打开文件", false) { openFile(job) })
            else if (job.status in listOf("queued", "downloading", "processing")) actions.addView(button("暂停", false) {
                Repo.update(job.id) { it.status = "paused" }
                startService(Intent(this, DownloadService::class.java).setAction("pause").putExtra("id", job.id))
            }) else if (job.status != "exporting") actions.addView(button("继续 / 重试", false) {
                if (Repo.activeJobId == job.id) {
                    Toast.makeText(this, "正在停止上次下载，请稍后再继续。", Toast.LENGTH_SHORT).show()
                    return@button
                }
                Repo.update(job.id) { it.status = "queued"; it.detail = "" }
                runCatching { startForegroundService(Intent(this, DownloadService::class.java)) }.onFailure { error -> Repo.update(job.id) { it.status = "failed"; it.detail = error.message ?: "启动失败" }; showError(error) }
            })
            actions.addView(button("详情", false) { AlertDialog.Builder(this).setTitle(job.title).setMessage("${job.url}\n\n${job.detail}").setPositiveButton("关闭", null).setNeutralButton("复制链接") { _, _ -> (getSystemService(CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("视频链接", job.url)) }.show() })
            if (job.status !in listOf("queued", "downloading", "processing", "exporting")) actions.addView(button("移除", false) { Repo.remove(job.id) })
            card.addView(actions); tasks.addView(card); tasks.addView(space(10))
        }
    }
    private fun openFile(job: Job) {
        runCatching {
            val uri = Uri.parse(job.contentUri)
            startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, contentResolver.getType(uri) ?: "video/*").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
        }.onFailure { showError(IllegalStateException("无法打开文件，请在系统文件管理器的 Download/拾流 中查看。")) }
    }
    private fun showSettings() {
        AlertDialog.Builder(this).setTitle("拾流 · 偏好设置")
            .setMessage("拾流 1.0.1\n下载位置：系统 Download/拾流\n\nyt-dlp：${Repo.engineVersion.ifBlank { "初始化中" }}\n${Repo.engineError}\n\n抖音网页验证只在本机保存状态。需要时打开官方网页完成验证后重试。\n\n支持 Android 10 及以上。后台下载使用前台服务，强制停止应用后需手动继续。\n\nGPL-3.0-or-later\nyt-dlp / youtubedl-android / FFmpeg")
            .setNegativeButton("抖音网页验证") { _, _ -> openDouyinBrowser() }
            .setPositiveButton("完成", null).setNeutralButton("更新下载引擎") { _, _ ->
                preview.text = "正在更新引擎…"
                Repo.metadataExecutor.execute {
                    val result = runCatching { Repo.updateEngine() }
                    runOnUiThread { result.onSuccess { preview.text = "引擎更新完成。" }.onFailure { showError(it); preview.text = "更新失败，现有引擎仍可使用。" } }
                }
            }.show()
    }
    private fun status(value: String) = mapOf("queued" to "等待下载", "downloading" to "正在下载", "processing" to "合并 / 转换中", "exporting" to "正在保存", "paused" to "已暂停", "completed" to "已完成", "failed" to "下载失败")[value] ?: value
    private fun openDouyinBrowser() {
        val url = runCatching { Input.validate(input.text.toString()) }.getOrNull()?.takeIf { Input.isDouyin(it) } ?: "https://www.douyin.com/"
        startActivityForResult(Intent(this, DouyinBrowserActivity::class.java).putExtra("url", url), 22)
    }
    @Deprecated("Legacy activity result API")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 22 && resultCode == RESULT_OK) {
            data?.getStringExtra("url")?.takeIf { Input.videoId(it) != null }?.let { input.setText(it) }
            preview.text = if (data?.getBooleanExtra("captured", false) == true) "已选择网页当前视频，可加入队列。画质以当前播放源为准。" else "网页状态已保存，请重新解析或重试下载。"
        }
    }
    private fun showError(error: Throwable) {
        if (isDestroyed) return
        val raw = error.message ?: error.toString()
        AlertDialog.Builder(this).setTitle("需要处理").setMessage(FailureMessage.message(raw)).setPositiveButton("知道了", null)
            .setNeutralButton("详细信息") { _, _ -> AlertDialog.Builder(this).setTitle("原始错误").setMessage(raw.takeLast(6000)).setPositiveButton("关闭", null).show() }.show()
    }
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
    private fun column() = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
    private fun row() = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
    private fun space(value: Int) = Space(this).apply { layoutParams = LinearLayout.LayoutParams(dp(value), dp(value)) }
    private fun label(text: String, size: Int, color: Int, bold: Boolean = false) = TextView(this).apply { this.text = text; textSize = size.toFloat(); setTextColor(color); if (bold) setTypeface(null, Typeface.BOLD) }
    private fun shape(color: Int, radius: Int) = GradientDrawable().apply { setColor(color); cornerRadius = dp(radius).toFloat() }
    private fun button(text: String, primary: Boolean, click: () -> Unit) = Button(this).apply {
        this.text = text; textSize = 12f; isAllCaps = false; minWidth = 0; minimumWidth = 0; minHeight = 0; minimumHeight = 0
        setTextColor(if (primary) Color.WHITE else green); background = shape(if (primary) green else Color.WHITE, 10)
        setPadding(dp(14), dp(10), dp(14), dp(10)); stateListAnimator = null; setOnClickListener { click() }
    }
}
