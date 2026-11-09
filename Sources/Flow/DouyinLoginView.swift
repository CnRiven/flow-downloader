import AppKit
import SwiftUI
import WebKit
import FlowCore

@MainActor final class DouyinBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    let web: WKWebView
    let session: DouyinWebSession
    @Published var page = ""
    @Published var message = "请在抖音官方网页完成验证或登录，随后保存状态。也可播放目标视频后使用当前视频。"
    @Published var saving = false
    let completion: (String, Bool) -> Void
    var didClose: (() -> Void)?
    func windowWillClose(_ notification: Notification) {
        web.stopLoading()
        if let window = notification.object as? NSWindow { window.parent?.removeChildWindow(window) }
        didClose?()
    }
    init(source: String, session: DouyinWebSession, completion: @escaping (String, Bool) -> Void) {
        self.session = session; self.completion = completion
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = session.store
        configuration.mediaTypesRequiringUserActionForPlayback = []
        web = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        web.customUserAgent = DouyinAccess.userAgent
        web.navigationDelegate = self; web.uiDelegate = self
        page = Input.isDouyin(source) ? source : "https://www.douyin.com/"
        web.load(URLRequest(url: URL(string: page)!))
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let main = navigationAction.targetFrame?.isMainFrame ?? true
        let allowed = url.scheme == "https" && url.user == nil && url.password == nil && (!main || Input.isDouyin(url.absoluteString))
        if !allowed { message = "请在当前官方网页完成操作；应用不会自动打开抖音 App 或外部登录页面。" }
        decisionHandler(allowed ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { page = webView.url?.absoluteString ?? page }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { message = "网页加载失败：" + error.localizedDescription }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, url.scheme == "https", Input.isDouyin(url.absoluteString) { webView.load(URLRequest(url: url)) }
        return nil
    }
    func save(useVideo: Bool) {
        guard !saving else { return }; saving = true
        Task {
            defer { saving = false }
            do {
                let source = web.url?.absoluteString ?? page
                guard Input.isDouyin(source) else { throw InputError.invalidURL }
                if useVideo {
                    let script = """
                    (() => { const vs = [...document.querySelectorAll('video')].filter(v => { const r=v.getBoundingClientRect(); return r.width>0 && r.height>0; });
                    const v=vs.find(v=>!v.paused && !v.ended) || (vs.length===1 ? vs[0] : null);
                    return {source:location.href, url:v ? v.currentSrc : '', title:document.title || '抖音视频', duration:v && Number.isFinite(v.duration) ? v.duration : null}; })()
                    """
                    guard let value = try await web.evaluateJavaScript(script) as? [String: Any], let current = value["source"] as? String,
                          let url = value["url"] as? String, Input.isDouyin(current) else { throw InputError.processFailed("请先在目标页面播放视频。") }
                    guard Input.videoID(current) != nil, DouyinAccess.isMediaURL(url) else {
                        throw InputError.processFailed("请先在目标视频页面播放视频。当前播放器未提供可下载的 HTTPS 视频地址；blob 或仅限 App 的视频暂不支持。")
                    }
                    try await session.save()
                    try session.remember(.init(source: current, url: url, title: value["title"] as? String ?? "抖音视频", duration: value["duration"] as? Double, savedAt: Date()))
                    completion(Input.canonicalize(current), true)
                } else {
                    try await session.save()
                    completion(Input.canonicalize(source), false)
                }
            } catch { message = error.localizedDescription }
        }
    }
}

private struct OfficialWebView: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct DouyinLoginView: View {
    @ObservedObject var browser: DouyinBrowser
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("抖音登录 / 网页验证").font(.title2).bold()
                Spacer(); Button("刷新") { browser.web.reload() }; Button("关闭", action: close)
            }
            Text(browser.message).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
            Text(browser.page).font(.system(size: 11, design: .monospaced)).lineLimit(1).textSelection(.enabled)
            OfficialWebView(web: browser.web).frame(minWidth: 900, minHeight: 540)
            HStack {
                Text("登录和 Cookie 保存在本机；关闭窗口不会自动保存给下载引擎。").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if browser.saving { ProgressView().controlSize(.small) }
                Button("保存状态并重试") { browser.save(useVideo: false) }.disabled(browser.saving)
                Button("使用当前视频") { browser.save(useVideo: true) }.disabled(browser.saving).buttonStyle(.borderedProminent)
            }
        }.padding(18).frame(minWidth: 980, minHeight: 700)
            .background(Color.white).foregroundStyle(Color.black).preferredColorScheme(.light)
    }
}
