import Foundation
import WebKit
import FlowCore

final class PreparedWebAccess {
    let access: DouyinAccess
    private let directory: URL
    init(access: DouyinAccess, directory: URL) { self.access = access; self.directory = directory }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

@MainActor final class DouyinWebSession {
    struct Video {
        let source: String
        let url: String
        let title: String
        let duration: Double?
        let savedAt: Date
    }
    private let preferences: UserDefaults
    private let isolated: Bool
    private var videos: [String: Video] = [:]
    lazy var store: WKWebsiteDataStore = isolated ? .nonPersistent() : .default()
    var enabled: Bool { preferences.bool(forKey: "douyinWebStateEnabled") }
    init(preferences: UserDefaults, isolated: Bool) { self.preferences = preferences; self.isolated = isolated }
    func cookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in store.httpCookieStore.getAllCookies { continuation.resume(returning: $0) } }
    }
    func save() async throws {
        let text = DouyinAccess.cookieText(await cookies())
        guard text.split(separator: "\n").count > 1 else { throw InputError.processFailed("尚未取得抖音网页状态，请先完成页面验证或登录。") }
        preferences.set(true, forKey: "douyinWebStateEnabled")
    }
    func remember(_ video: Video) throws {
        guard Input.videoID(video.source) != nil, DouyinAccess.isMediaURL(video.url) else {
            throw InputError.processFailed("尚未找到可下载的当前视频。请在目标视频页面播放后重试；blob 视频或仅能在抖音 App 观看的页面暂不支持。")
        }
        videos[Input.canonicalize(video.source)] = video
    }
    func prepare(_ source: String) async throws -> PreparedWebAccess? {
        guard Input.isDouyin(source) else { return nil }
        let key = Input.canonicalize(source)
        let video = videos[key].flatMap { Date().timeIntervalSince($0.savedAt) < 600 ? $0 : nil }
        guard enabled || video != nil else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Flow-session-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            var cookieFile: URL?
            if enabled {
                let file = directory.appendingPathComponent("cookies.txt")
                try DouyinAccess.cookieText(await cookies()).write(to: file, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                cookieFile = file
            }
            var infoFile: URL?, preview: VideoInfo?
            if let video {
                let id = Input.videoID(key)!
                var metadata: [String: Any] = ["id": id, "title": video.title, "webpage_url": key, "extractor": "webpage",
                    "formats": [["format_id": "web", "url": video.url, "ext": "mp4", "vcodec": "unknown", "acodec": "unknown",
                                  "http_headers": ["User-Agent": DouyinAccess.userAgent, "Referer": key]]]]
                if let duration = video.duration, duration.isFinite { metadata["duration"] = duration }
                let data = try JSONSerialization.data(withJSONObject: metadata)
                preview = try JSONDecoder().decode(VideoInfo.self, from: data)
                let file = directory.appendingPathComponent("video.json")
                try data.write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                infoFile = file
            }
            return PreparedWebAccess(access: DouyinAccess(source: key, cookieFile: cookieFile, infoFile: infoFile, preview: preview), directory: directory)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    func clear() async {
        preferences.removeObject(forKey: "douyinWebStateEnabled"); videos.removeAll()
        await withCheckedContinuation { continuation in
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { continuation.resume() }
        }
    }
}
