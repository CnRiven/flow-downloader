import Foundation
import CryptoKit
import Darwin

public enum EngineInstallError: LocalizedError {
    case network(String), invalidRelease, checksum, invalidExecutable, oversized, timedOut
    public var errorDescription: String? {
        switch self {
        case .network(let message): return "下载引擎安装失败：\(message)。请检查网络后重试。"
        case .invalidRelease: return "无法读取 yt-dlp 官方发布信息，请稍后重试。"
        case .checksum: return "下载文件的 SHA-256 校验不一致，已丢弃该文件。请重新安装。"
        case .invalidExecutable: return "下载的引擎未能通过运行检查，原有安装已保留。"
        case .oversized: return "下载文件超过预期大小，安装已停止。"
        case .timedOut: return "引擎运行检查超时，请重试安装。"
        }
    }
}

public struct EngineInstallProgress: Sendable {
    public let message: String
    public let fraction: Double?
    public init(_ message: String, fraction: Double? = nil) { self.message = message; self.fraction = fraction }
}

public struct InstalledEngine: Sendable {
    public let url: URL
    public let version: String
    public let sha256: String
}

public protocol EngineInstallTransport: Sendable {
    func data(from url: URL, maximumBytes: Int) async throws -> Data
    func download(from url: URL, to destination: URL, maximumBytes: Int64,
                  progress: @escaping @Sendable (Int64, Int64) -> Void) async throws
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let maximum: Int64
    let progress: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var exceeded = false
    private var lastUpdate = Date.distantPast
    var oversized: Bool { lock.lock(); defer { lock.unlock() }; return exceeded }
    init(maximum: Int64, progress: @escaping @Sendable (Int64, Int64) -> Void) { self.maximum = maximum; self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximum || totalBytesExpectedToWrite > maximum {
            lock.lock(); exceeded = true; lock.unlock(); downloadTask.cancel(); return
        }
        let now = Date()
        if now.timeIntervalSince(lastUpdate) >= 0.1 || totalBytesWritten == totalBytesExpectedToWrite {
            lastUpdate = now; progress(totalBytesWritten, totalBytesExpectedToWrite)
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(URLSessionEngineTransport.isTrusted) == true ? request : nil)
    }
}

public struct URLSessionEngineTransport: EngineInstallTransport {
    public init() {}
    fileprivate static func isTrusted(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, let host = url.host?.lowercased() else { return false }
        return ["github.com", "api.github.com"].contains(host) || host.hasSuffix(".githubusercontent.com")
    }
    private func request(_ url: URL) throws -> URLRequest {
        guard Self.isTrusted(url) else { throw EngineInstallError.invalidRelease }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Flow/1.0.2 (macOS)", forHTTPHeaderField: "User-Agent")
        return request
    }
    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, let url = http.url, Self.isTrusted(url) else { throw EngineInstallError.invalidRelease }
        guard http.statusCode == 200 else {
            let reason = http.statusCode == 403 ? "GitHub 暂时拒绝访问或请求次数已达上限" : "GitHub 返回 HTTP \(http.statusCode)"
            throw EngineInstallError.network(reason)
        }
    }
    public func data(from url: URL, maximumBytes: Int) async throws -> Data {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request(url))
        try validate(response)
        guard data.count <= maximumBytes else { throw EngineInstallError.oversized }
        return data
    }
    public func download(from url: URL, to destination: URL, maximumBytes: Int64,
                         progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let delegate = DownloadDelegate(maximum: maximumBytes, progress: progress)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 300
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (file, response) = try await session.download(for: request(url), delegate: delegate)
            defer { try? FileManager.default.removeItem(at: file) }
            try validate(response)
            let size = (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= maximumBytes else { throw EngineInstallError.oversized }
            try FileManager.default.copyItem(at: file, to: destination)
        } catch {
            if delegate.oversized { throw EngineInstallError.oversized }
            throw error
        }
    }
}

public enum EngineProbe {
    public static func version(at path: String) async throws -> String {
        let process = EngineProcess()
        let output = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await process.run(executable: path, arguments: ["--version"], onLine: { _ in })
                } onCancel: { process.cancel() }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 20_000_000_000)
                process.cancel(); throw EngineInstallError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard version.range(of: #"^\d{4}\.\d{2}\.\d{2}[A-Za-z0-9._+\-]*$"#, options: .regularExpression) != nil else {
            throw EngineInstallError.invalidExecutable
        }
        return version
    }
}

public struct EngineInstaller {
    public static let releaseURL = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!
    private let transport: any EngineInstallTransport
    public init(transport: any EngineInstallTransport = URLSessionEngineTransport()) { self.transport = transport }

    private struct Release: Decodable {
        let tag_name: String
        let assets: [Asset]
        struct Asset: Decodable { let name: String; let size: Int64; let browser_download_url: String }
    }

    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func install(to directory: URL = EnginePaths.managedBinDirectory,
                        progress: @escaping @Sendable (EngineInstallProgress) -> Void = { _ in }) async throws -> InstalledEngine {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = directory.appendingPathComponent(".install-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        do {
            progress(EngineInstallProgress("正在获取 yt-dlp 官方版本…"))
            let metadata = try await transport.data(from: Self.releaseURL, maximumBytes: 4 * 1024 * 1024)
            let release = try JSONDecoder().decode(Release.self, from: metadata)
            guard release.tag_name.range(of: #"^\d{4}\.\d{2}\.\d{2}[A-Za-z0-9._\-]*$"#, options: .regularExpression) != nil,
                  let asset = release.assets.first(where: { $0.name == "yt-dlp_macos" }),
                  asset.size > 0, asset.size <= 200 * 1024 * 1024 else { throw EngineInstallError.invalidRelease }
            let base = "https://github.com/yt-dlp/yt-dlp/releases/download/" + release.tag_name + "/"
            guard asset.browser_download_url == base + "yt-dlp_macos",
                  let sumsAsset = release.assets.first(where: { $0.name == "SHA2-256SUMS" }),
                  sumsAsset.browser_download_url == base + "SHA2-256SUMS" else { throw EngineInstallError.invalidRelease }
            let sums = try await transport.data(from: URL(string: base + "SHA2-256SUMS")!, maximumBytes: 1024 * 1024)
            let hashes = String(decoding: sums, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { line -> String? in
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard fields.count == 2, fields[1].trimmingCharacters(in: CharacterSet(charactersIn: "*")) == "yt-dlp_macos",
                      fields[0].range(of: #"^[A-Fa-f0-9]{64}$"#, options: .regularExpression) != nil else { return nil }
                return fields[0].lowercased()
            }
            guard hashes.count == 1, let expected = hashes.first else { throw EngineInstallError.invalidRelease }
            try Task.checkCancellation()
            let candidate = staging.appendingPathComponent("yt-dlp")
            progress(EngineInstallProgress("正在下载 yt-dlp \(release.tag_name)…", fraction: 0))
            try await transport.download(from: URL(string: asset.browser_download_url)!, to: candidate, maximumBytes: asset.size) { bytes, _ in
                progress(EngineInstallProgress("正在下载 yt-dlp \(release.tag_name)…", fraction: min(1, Double(bytes) / Double(asset.size))))
            }
            try Task.checkCancellation()
            progress(EngineInstallProgress("正在校验下载文件…", fraction: 1))
            let size = try candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size == asset.size, try Self.sha256(of: candidate) == expected else { throw EngineInstallError.checksum }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: candidate.path)
            progress(EngineInstallProgress("正在检查引擎是否可以运行…", fraction: 1))
            let version = try await EngineProbe.version(at: candidate.path)
            guard version == release.tag_name else { throw EngineInstallError.invalidExecutable }
            try Task.checkCancellation()
            let destination = directory.appendingPathComponent("yt-dlp")
            let result = candidate.path.withCString { from in destination.path.withCString { to in Darwin.rename(from, to) } }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            progress(EngineInstallProgress("下载引擎已就绪", fraction: 1))
            return InstalledEngine(url: destination, version: version, sha256: expected)
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as EngineInstallError { throw error }
        catch let error as URLError { throw EngineInstallError.network(error.localizedDescription) }
        catch { throw error }
    }
}
