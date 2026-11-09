import Foundation

public struct DouyinAccess {
    public static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    public let source: String
    public let cookieFile: URL?
    public let infoFile: URL?
    public let preview: VideoInfo?
    public init(source: String, cookieFile: URL?, infoFile: URL? = nil, preview: VideoInfo? = nil) {
        self.source = source; self.cookieFile = cookieFile; self.infoFile = infoFile; self.preview = preview
    }
    public func applies(to url: String) -> Bool { Input.isDouyin(url) && Input.isDouyin(source) }
    public func hasSelectedVideo(for url: String) -> Bool {
        applies(to: url) && Input.videoID(source) != nil && Input.videoID(source) == Input.videoID(url) && infoFile != nil
    }
    public static func isMediaURL(_ value: String) -> Bool {
        guard let url = URL(string: value), url.scheme == "https", url.user == nil, url.password == nil, let host = url.host?.lowercased() else { return false }
        return ["douyinvod.com", "bytecdn.cn", "bytecdn.com", "ibytedtos.com", "pstatp.com", "snssdk.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
    public static func cookieText(_ cookies: [HTTPCookie], now: Date = Date()) -> String {
        let lines = cookies.compactMap { cookie -> String? in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard Input.isDouyin("https://" + domain), cookie.expiresDate.map({ $0 > now }) ?? true,
                  [cookie.domain, cookie.path, cookie.name, cookie.value].allSatisfy({ !$0.contains(where: { $0 == "\t" || $0 == "\r" || $0 == "\n" }) }) else { return nil }
            let expires = cookie.expiresDate.map { String(Int($0.timeIntervalSince1970)) } ?? "0"
            return [cookie.isHTTPOnly ? "#HttpOnly_" + cookie.domain : cookie.domain,
                    cookie.domain.hasPrefix(".") ? "TRUE" : "FALSE", cookie.path, cookie.isSecure ? "TRUE" : "FALSE", expires, cookie.name, cookie.value].joined(separator: "\t")
        }
        return "# Netscape HTTP Cookie File\n" + lines.joined(separator: "\n") + "\n"
    }
}

public enum FailureMessage {
    public static func needsDouyinLogin(_ message: String, url: String) -> Bool {
        guard Input.isDouyin(url) else { return false }
        let lower = message.lowercased()
        return ["fresh cookies", "cookies are needed", "login", "sign in", "captcha", "verify", "403", "unsupported url", "empty video", "unable to extract"].contains { lower.contains($0) }
    }
    public static func display(_ message: String, url: String) -> String {
        needsDouyinLogin(message, url: url) ? "抖音需要新的网页验证或登录状态。请打开「抖音登录 / 验证」，在官方网页完成后保存状态并重试；也可播放目标视频后选择「使用当前视频」。" : message
    }
}
