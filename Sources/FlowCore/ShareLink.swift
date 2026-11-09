import Foundation

public enum Input {
    public static func validatedURL(_ input: String) throws -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{200B}\u{FEFF}")))
        let regex = try! NSRegularExpression(pattern: #"https?://[^\s<>"“”‘’（）【】\[\]()，。；！、\u200B\uFEFF]+"#, options: .caseInsensitive)
        let candidate: String
        if text.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil && !text.contains(where: \.isWhitespace) {
            candidate = text
        } else {
            guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range, in: text) else { throw InputError.invalidURL }
            candidate = String(text[range])
        }
        let value = candidate.trimmingCharacters(in: CharacterSet(charactersIn: ".,;!。；，！"))
        // Reject a command or a second line appended to an otherwise bare URL.
        if text.lowercased().hasPrefix("http"), text.contains("\n--") { throw InputError.invalidURL }
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { throw InputError.invalidURL }
        return canonicalize(value)
    }

    public static func isDouyin(_ value: String) -> Bool {
        guard let host = URL(string: value)?.host?.lowercased() else { return false }
        return ["douyin.com", "iesdouyin.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
    public static func videoID(_ value: String) -> String? {
        guard isDouyin(value), let url = URLComponents(string: value) else { return nil }
        let pattern = try! NSRegularExpression(pattern: #"/(?:share/|xg/)?video/(\d+)(?:/|$)"#)
        if let match = pattern.firstMatch(in: url.path, range: NSRange(url.path.startIndex..., in: url.path)),
           let range = Range(match.range(at: 1), in: url.path) { return String(url.path[range]) }
        return url.queryItems?.first(where: { ["modal_id", "aweme_id", "item_id"].contains($0.name) && $0.value?.range(of: #"^\d+$"#, options: .regularExpression) != nil })?.value
    }
    public static func canonicalize(_ value: String) -> String {
        videoID(value).map { "https://www.douyin.com/video/" + $0 } ?? value
    }
}

public enum DouyinLinkError: LocalizedError {
    case redirect, http(Int), tooManyRedirects
    public var errorDescription: String? {
        switch self {
        case .redirect: return "抖音短链接跳转到了无法识别的地址，请在抖音官方网页中打开。"
        case .http(let status): return "抖音短链接访问失败（HTTP \(status)），请在抖音官方网页中打开。"
        case .tooManyRedirects: return "抖音短链接跳转次数过多，请重新复制分享链接。"
        }
    }
}

public struct LinkResponse: Sendable {
    public let status: Int
    public let location: String?
    public init(status: Int, location: String?) { self.status = status; self.location = location }
}
public protocol LinkTransport: Sendable { func response(for url: URL) async throws -> LinkResponse }
private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
public struct OfficialLinkTransport: LinkTransport {
    public init() {}
    public func response(for url: URL) async throws -> LinkResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false; configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(DouyinAccess.userAgent, forHTTPHeaderField: "User-Agent")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DouyinLinkError.redirect }
        return LinkResponse(status: http.statusCode, location: http.value(forHTTPHeaderField: "Location"))
    }
}
public struct DouyinLinkResolver {
    private let transport: any LinkTransport
    public init(transport: any LinkTransport = OfficialLinkTransport()) { self.transport = transport }
    public func resolve(_ input: String) async throws -> String {
        var source = try Input.validatedURL(input)
        guard Input.isDouyin(source) else { return source }
        for _ in 0..<8 {
            try Task.checkCancellation()
            if Input.videoID(source) != nil { return Input.canonicalize(source) }
            guard let url = URL(string: source), url.scheme == "https" else { throw DouyinLinkError.redirect }
            let result = try await transport.response(for: url)
            if [301, 302, 303, 307, 308].contains(result.status) {
                guard let location = result.location, let next = URL(string: location, relativeTo: url)?.absoluteURL,
                      next.scheme == "https", next.user == nil, next.password == nil, Input.isDouyin(next.absoluteString) else { throw DouyinLinkError.redirect }
                source = Input.canonicalize(next.absoluteString)
            } else {
                guard (200..<300).contains(result.status) else { throw DouyinLinkError.http(result.status) }
                return source
            }
        }
        throw DouyinLinkError.tooManyRedirects
    }
}
