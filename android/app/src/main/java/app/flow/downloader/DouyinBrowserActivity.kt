package app.flow.downloader

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.webkit.*
import android.view.ViewGroup
import android.widget.*
import org.json.JSONObject
import org.json.JSONTokener

/** Visible official website. Credentials stay in Android WebView's local cookie store. */
class DouyinBrowserActivity : Activity() {
    private lateinit var web: WebView
    private lateinit var status: TextView
    private var requested = "https://www.douyin.com/"
    private val observedVideos = java.util.Collections.synchronizedSet(mutableSetOf<String>())

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        requested = intent.getStringExtra("url")?.takeIf { Input.isDouyin(it) } ?: requested
        val layout = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(12, 12, 12, 12); setBackgroundColor(Color.WHITE) }
        status = TextView(this).apply { setText(R.string.douyin_browser_intro); textSize = 13f; setPadding(12, 10, 12, 10) }
        layout.addView(status)
        val buttons = LinearLayout(this)
        fun action(title: String, callback: () -> Unit) = Button(this).apply { text = title; textSize = 11f; isAllCaps = false; setOnClickListener { callback() } }
        buttons.addView(action("返回") { finish() }, LinearLayout.LayoutParams(0, -2, 1f))
        buttons.addView(action("保存验证状态") { save(false) }, LinearLayout.LayoutParams(0, -2, 1f))
        buttons.addView(action("使用当前视频") { save(true) }, LinearLayout.LayoutParams(0, -2, 1f))
        layout.addView(buttons)
        web = WebView(this)
        web.settings.apply {
            javaScriptEnabled = true; domStorageEnabled = true; mediaPlaybackRequiresUserGesture = false
            allowFileAccess = false; allowContentAccess = false; mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            userAgentString = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
            useWideViewPort = true; loadWithOverviewMode = true; builtInZoomControls = true; displayZoomControls = false
        }
        CookieManager.getInstance().setAcceptCookie(true)
        CookieManager.getInstance().setAcceptThirdPartyCookies(web, false)
        web.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                val uri = request.url
                // Never hand deep links or arbitrary external pages to another app.
                return uri.scheme != "https" || !Input.isDouyin(uri.toString())
            }
            override fun onPageStarted(view: WebView?, url: String?, favicon: android.graphics.Bitmap?) { observedVideos.clear() }
            override fun onPageFinished(view: WebView?, url: String?) { status.text = "官方页面已打开。完成验证后保存状态，或播放目标视频后点击「使用当前视频」。" }
            override fun shouldInterceptRequest(view: WebView?, request: WebResourceRequest?): WebResourceResponse? {
                request?.url?.toString()?.takeIf { DouyinSession.isVideoUrl(it) }?.let { synchronized(observedVideos) { if (observedVideos.size < 20) observedVideos.add(it) } }
                return null
            }
        }
        layout.addView(web, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        setContentView(layout)
        if (android.os.Build.VERSION.SDK_INT >= 30) layout.setOnApplyWindowInsetsListener { view, insets ->
            val bars = insets.getInsets(android.view.WindowInsets.Type.systemBars())
            view.setPadding(bars.left + 12, bars.top + 12, bars.right + 12, bars.bottom + 12); insets
        }
        web.loadUrl(requested)
    }

    private fun save(useVideo: Boolean) {
        val page = web.url?.takeIf { Input.isDouyin(it) } ?: requested
        DouyinSession.saveCookies(this, web.settings.userAgentString)
        if (!useVideo) { setResult(RESULT_OK, Intent().putExtra("url", Input.canonicalize(page))); finish(); return }
        web.evaluateJavascript("(function(){var vs=document.querySelectorAll('video'),v=null;for(var i=0;i<vs.length;i++){if(!vs[i].paused){v=vs[i];break;}}v=v||vs[0];return JSON.stringify({url:v?v.currentSrc:'',title:document.title||''});})()") { encoded ->
            runCatching {
                val decoded = JSONTokener(encoded).nextValue() as? String ?: error("请先在网页中播放目标视频。")
                val value = JSONObject(decoded)
                val observed = synchronized(observedVideos) { observedVideos.toList() }
                val direct = value.optString("url").takeIf { DouyinSession.isVideoUrl(it) } ?: observed.singleOrNull()
                    ?: error("尚未捕获到可下载的视频，请先播放目标视频。如果页面要求在抖音 App 内查看，该页面暂时无法下载。")
                require(Input.videoId(page) != null) { "请先打开目标视频的页面，再使用当前视频。" }
                val title = value.optString("title").takeIf { it.isNotBlank() } ?: "抖音视频"
                DouyinSession.remember(BrowserVideo(Input.canonicalize(page), direct, title, web.settings.userAgentString))
                setResult(RESULT_OK, Intent().putExtra("url", Input.canonicalize(page)).putExtra("captured", true)); finish()
            }.onFailure { android.app.AlertDialog.Builder(this).setMessage(it.message).setPositiveButton("知道了", null).show() }
        }
    }
    override fun onDestroy() {
        if (::web.isInitialized) { web.stopLoading(); (web.parent as? ViewGroup)?.removeView(web); web.destroy() }
        super.onDestroy()
    }
}
