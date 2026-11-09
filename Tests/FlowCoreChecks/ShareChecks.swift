import Foundation
import FlowCore

enum ShareChecks {
    static let example = "7.41 :5pm q@E.HI seb:/ 11/05 精讲《亮剑》之李云龙突击楚云飞，未果，顺手包圆暂七师 # 李云龙 # 楚云飞 # 打卡 # 伍解千剧 # 抖音精选  https://v.douyin.com/eJPm0zOllNw/ 复制此链接，打开Dou音搜索，直接观看视频！"
    private static func expect(_ value: Bool, _ message: String) throws { if !value { throw InputError.processFailed(message) } }
    private struct Stub: LinkTransport {
        let location: String
        func response(for url: URL) async throws -> LinkResponse { LinkResponse(status: 302, location: location) }
    }
    static func run() async throws {
        try expect(try Input.validatedURL(example) == "https://v.douyin.com/eJPm0zOllNw/", "User's Douyin share text was rejected")
        for text in ["复制【https://v.douyin.com/abc/】观看", "视频 (https://v.douyin.com/abc/)。", "看看 [作品](https://v.douyin.com/abc/)！"] {
            try expect(try Input.validatedURL(text) == "https://v.douyin.com/abc/", "Share punctuation broke URL extraction")
        }
        for value in ["https://www.iesdouyin.com/share/video/7651105998492519707/?app=video_article", "https://www.iesdouyin.com/xg/video/7651105998492519707/", "https://www.douyin.com/?modal_id=7651105998492519707"] {
            try expect(try Input.validatedURL(value) == "https://www.douyin.com/video/7651105998492519707", "Douyin URL was not canonicalized")
        }
        try expect(!Input.isDouyin("https://douyin.com.evil.test/video/123") && !Input.isDouyin("https://evildouyin.com/"), "Lookalike domain was trusted")
        let source = try await DouyinLinkResolver(transport: Stub(location: "https://www.iesdouyin.com/share/video/7651105998492519707/?tracking=1")).resolve(example)
        try expect(source == "https://www.douyin.com/video/7651105998492519707", "Short redirect did not reach official extractor URL")
        for location in ["https://evil.test/video/123", "file:///tmp/video", "http://www.douyin.com/video/123", "https://user:secret@www.douyin.com/video/123"] {
            do { _ = try await DouyinLinkResolver(transport: Stub(location: location)).resolve(example); throw InputError.processFailed("Unsafe redirect accepted") }
            catch DouyinLinkError.redirect {}
        }
        do { _ = try await DouyinLinkResolver(transport: Stub(location: "/loop")).resolve(example); throw InputError.processFailed("Redirect loop accepted") }
        catch DouyinLinkError.tooManyRedirects {}
        func cookie(_ domain: String, _ value: String) -> HTTPCookie {
            HTTPCookie(properties: [.domain: domain, .path: "/", .name: "sessionid", .value: value, .secure: "TRUE"])!
        }
        let text = DouyinAccess.cookieText([cookie(".douyin.com", "test-douyin"), cookie(".iesdouyin.com", "test-share"), cookie(".example.com", "test-unrelated")])
        try expect(text.contains("test-douyin") && text.contains("test-share") && !text.contains("test-unrelated"), "Unrelated website cookies were exported")
        let access = DouyinAccess(source: source, cookieFile: URL(fileURLWithPath: "/tmp/test-cookies"), infoFile: URL(fileURLWithPath: "/tmp/test-video"))
        let engine = DownloadEngine(paths: EnginePaths(downloader: "/test", ffmpeg: "/test/ffmpeg"))
        let args = engine.arguments(for: DownloadJob(url: source, info: nil, quality: .hd1080, directory: "/tmp"), access: access)
        try expect(args.contains("--load-info-json") && args.contains("--cookies") && args.contains("b[height<=?1080]"), "Explicit web video or cookies were ignored")
        let external = engine.arguments(for: DownloadJob(url: "https://example.com/video", info: nil, quality: .best, directory: "/tmp"), access: access)
        try expect(!external.contains("--load-info-json") && !external.contains("--cookies"), "Douyin session leaked to another website")
        try expect(!access.hasSelectedVideo(for: "https://www.douyin.com/video/999"), "Selected video was reused for a different post")
        try expect(FailureMessage.needsDouyinLogin("Fresh cookies (not necessarily logged in) are needed", url: source), "Fresh-cookie error has no login recovery")
        print("PASS Douyin share text, canonical URLs, restricted redirects, cookie scoping and login recovery")
        if ProcessInfo.processInfo.environment["FLOW_REAL_DOUYIN_LINK"] != nil {
            let resolved = try await DouyinLinkResolver().resolve(example)
            try expect(resolved == source, "Real sample resolved to another post")
            print("PASS real user-provided Douyin short link ->", resolved)
        }
    }
}
