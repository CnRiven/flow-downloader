import Foundation
import WebKit
import FlowCore

@MainActor enum WebCaptureChecks {
    private final class Listener: NSObject, WKScriptMessageHandler {
        var candidates: [WebVideoCandidate] = []
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if let value = WebVideoCandidate.decode(message.body) { candidates.append(value) }
        }
    }
    static func run(url: String) async throws {
        let listener = Listener(), config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addUserScript(WKUserScript(source: #"""
        window.fetch = async () => ({ok:true,headers:{get:()=>null},clone:()=>({text:async()=>JSON.stringify({aweme_detail:{aweme_id:'111',desc:'Fetch video',video:{duration:12000,play_addr:{url_list:['https://media.douyinvod.com/video/fetch.mp4']}}},related:{aweme_id:'222',video:{play_addr:{url_list:['https://media.douyinvod.com/video/other.mp4']}}}})})});
        window.XMLHttpRequest = class extends EventTarget {
          constructor(){super();this.status=200;this.responseType='json';this.response={aweme_detail:{aweme_id:'111',desc:'XHR video',video:{play_addr:{url_list:['https://media.douyinvod.com/video/xhr.mp4']}}}};}
          open(){} send(){this.dispatchEvent(new Event('load'));}
        };
        """#, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.addUserScript(WKUserScript(source: WebVideoCapture.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.add(listener, name: "flowVideo")
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        defer { web.stopLoading(); config.userContentController.removeScriptMessageHandler(forName: "flowVideo") }
        web.load(URLRequest(url: URL(string: url)!))
        try await ModelChecks.wait { !listener.candidates.isEmpty }
        try ModelChecks.expect(listener.candidates.allSatisfy { $0.id == "111" }, "Related post crossed the browser capture bridge")
        let first = try await web.evaluateJavaScript("window.__flowVideoCapture.read()")
        try ModelChecks.expect(first.flatMap(WebVideoCandidate.decode)?.title == "Fetch video", "Fetch metadata not captured for blob player")
        let blob = try await web.evaluateJavaScript("document.querySelector('video').src") as? String
        try ModelChecks.expect(blob?.hasPrefix("blob:") == true, "Fixture did not use blob playback")
        _ = try await web.evaluateJavaScript("var x=new XMLHttpRequest();x.open('GET','https://www.douyin.com/aweme/v1/web/aweme/detail/');x.send();")
        try await ModelChecks.wait { listener.candidates.count >= 2 }
        let second = try await web.evaluateJavaScript("window.__flowVideoCapture.read()")
        try ModelChecks.expect(second.flatMap(WebVideoCandidate.decode)?.title == "XHR video", "XHR response was not captured")
        _ = try await web.evaluateJavaScript("window._ROUTER_DATA={loaderData:{detail:{awemeId:'111',desc:'Camel video',video:{playAddr:[{src:'https://media.douyinvod.com/video/camel.mp4'}]}}}};")
        let camel = try await web.evaluateJavaScript("window.__flowVideoCapture.read()")
        try ModelChecks.expect(camel.flatMap(WebVideoCandidate.decode)?.title == "Camel video", "SSR camel-case array playAddr was not captured")
        _ = try await web.evaluateJavaScript("delete window._ROUTER_DATA; JSON.parse(JSON.stringify({aweme_id:'111',desc:'Hydrated video',video:{play_addr:{url_list:['https://media.douyinvod.com/video/hydrated.mp4']}}}));")
        let hydrated = try await web.evaluateJavaScript("window.__flowVideoCapture.read()")
        try ModelChecks.expect(hydrated.flatMap(WebVideoCandidate.decode)?.title == "Hydrated video", "Parsed hydration state was not captured")
        _ = try await web.evaluateJavaScript("document.querySelector('video')['__reactProps$fixture']={aweme:{awemeId:'111',desc:'Player video',video:{playAddr:[{src:'https://media.douyinvod.com/video/player.mp4'}]}}};")
        let player = try await web.evaluateJavaScript("window.__flowVideoCapture.read()")
        try ModelChecks.expect(player.flatMap(WebVideoCandidate.decode)?.title == "Player video", "Player component metadata was not captured")
        _ = try await web.evaluateJavaScript("history.pushState({},'', '/video/999');")
        let stale = try await web.evaluateJavaScript("window.__flowVideoCapture.read()")
        try ModelChecks.expect(stale == nil || stale is NSNull, "Navigation reused another video's address")
        print("PASS real WebKit blob playback capture: fetch, XHR, hydration, camel-case state, player component, related-post isolation and SPA navigation")
    }
}
