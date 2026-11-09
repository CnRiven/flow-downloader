import AppKit
import SwiftUI
import WebKit
import FlowCore

@MainActor final class DouyinBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate, WKScriptMessageHandler {
    let web: WKWebView
    let session: DouyinWebSession
    @Published var page = ""
    @Published var message = "请在抖音官方网页完成验证或登录，随后保存状态。也可播放目标视频后使用当前视频。"
    @Published var saving = false
    @Published private(set) var diagnostic = ""
    @Published private(set) var videoReady = false
    private var candidate: WebVideoCandidate?
    let completion: (String, Bool) -> Void
    var didClose: (() -> Void)?
    func windowWillClose(_ notification: Notification) {
        web.stopLoading()
        web.configuration.userContentController.removeScriptMessageHandler(forName: "flowVideo")
        if let window = notification.object as? NSWindow { window.parent?.removeChildWindow(window) }
        didClose?()
    }
    init(source: String, session: DouyinWebSession, completion: @escaping (String, Bool) -> Void) {
        self.session = session; self.completion = completion
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = session.store
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.addUserScript(WKUserScript(source: WebVideoCapture.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(self, name: "flowVideo")
        web.customUserAgent = DouyinAccess.userAgent
        web.navigationDelegate = self; web.uiDelegate = self
        page = Input.isDouyin(source) ? source : "https://www.douyin.com/"
        web.load(URLRequest(url: URL(string: page)!))
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let source = web.url?.absoluteString, Input.isDouyin(source),
              let value = WebVideoCandidate.decode(message.body), value.matches(source) else { return }
        candidate = value; videoReady = true
        self.message = "已识别目标视频的网页播放地址，可以直接读取并下载。"
    }
    func selectedVideo() async throws -> WebVideoCandidate? {
        let value = try await web.evaluateJavaScript("window.__flowVideoCapture ? window.__flowVideoCapture.read() : null")
        let source = web.url?.absoluteString ?? page
        if let value, let found = WebVideoCandidate.decode(value), found.matches(source) { candidate = found }
        return candidate.flatMap { $0.matches(source) ? $0 : nil }
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
                if let selected = try await selectedVideo(), let url = selected.mediaURL {
                    // A publicly playable video does not necessarily set a login cookie.
                    try? await session.save()
                    try session.remember(.init(source: source, url: url, title: selected.title, duration: selected.duration, savedAt: Date()))
                    completion(Input.canonicalize(source), true)
                } else {
                    if useVideo { throw InputError.processFailed("尚未读到目标视频地址。请播放几秒后重试，或刷新网页后再播放。此处不会重复要求你登录；加密流暂不支持。") }
                    try await session.save()
                    if Input.videoID(source) == nil { completion(Input.canonicalize(source), false) }
                    else { message = "登录状态已保存。请在当前网页播放目标视频几秒，再点击「读取网页视频并下载」。" }
                }
            } catch {
                message = error.localizedDescription
                if let info = try? await web.evaluateJavaScript("window.__flowVideoCapture?.diagnostics()"),
                   let data = try? JSONSerialization.data(withJSONObject: info, options: .sortedKeys), let text = String(data: data, encoding: .utf8) {
                    diagnostic = text
                }
            }
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
            if !browser.diagnostic.isEmpty {
                DisclosureGroup("查看网页诊断（不含登录信息）") { Text(browser.diagnostic).font(.system(size: 10, design: .monospaced)).textSelection(.enabled) }
            }
            Text(browser.page).font(.system(size: 11, design: .monospaced)).lineLimit(1).textSelection(.enabled)
            OfficialWebView(web: browser.web).frame(minWidth: 900, minHeight: 540)
            HStack {
                Text("登录和 Cookie 保存在本机；关闭窗口不会自动保存给下载引擎。").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if browser.saving { ProgressView().controlSize(.small) }
                Button(browser.videoReady ? "使用已识别视频" : "保存登录状态") { browser.save(useVideo: false) }.disabled(browser.saving)
                Button("读取网页视频并下载") { browser.save(useVideo: true) }.disabled(browser.saving).buttonStyle(.borderedProminent)
            }
        }.padding(18).frame(minWidth: 980, minHeight: 700)
            .background(Color.white).foregroundStyle(Color.black).preferredColorScheme(.light)
    }
}
