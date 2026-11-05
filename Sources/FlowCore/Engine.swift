import Foundation

private final class MetadataCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var json: Data?
    func accept(_ line: String) {
        guard line.hasPrefix("{") else { return }
        lock.lock(); json = line.data(using: .utf8); lock.unlock()
    }
    func data() -> Data? { lock.lock(); defer { lock.unlock() }; return json }
}

public struct EnginePaths {
    public static var managedBinDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flow/engines/bin", isDirectory: true)
    }
    public let downloader: String?
    public let ffmpeg: String?
    public let runtime: String?

    public init(bundle: Bundle = .main) {
        self.init(managedDirectory: Self.managedBinDirectory, searchDirectories:
            [bundle.resourcePath.map { $0 + "/bin" }].compactMap { $0 }
            + ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin",
               NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/.deno/bin", NSHomeDirectory() + "/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":"))
    }

    public init(managedDirectory: URL, searchDirectories: [String]) {
        let directories = [managedDirectory.path] + searchDirectories.filter { !$0.isEmpty }
        func find(_ name: String) -> String? {
            directories.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        downloader = find("yt-dlp"); ffmpeg = find("ffmpeg"); runtime = find("deno")
    }

    public init(downloader: String?, ffmpeg: String? = nil, runtime: String? = nil) {
        self.downloader = downloader; self.ffmpeg = ffmpeg; self.runtime = runtime
    }
}

public enum EngineEvent: Equatable, Sendable {
    case progress(Double, String, String)
    case processing
    case title(String)
    case file(String)
    case log(String)

    public static func parse(_ line: String) -> EngineEvent {
        if line.hasPrefix("FLOW_PROGRESS:"),
           let data = String(line.dropFirst("FLOW_PROGRESS:".count)).data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if value["status"] as? String == "finished" { return .processing }
            let downloaded = (value["downloaded_bytes"] as? NSNumber)?.doubleValue ?? 0
            let total = (value["total_bytes"] as? NSNumber)?.doubleValue ?? (value["total_bytes_estimate"] as? NSNumber)?.doubleValue ?? 0
            let speed = (value["speed"] as? NSNumber)?.doubleValue ?? 0
            let eta = (value["eta"] as? NSNumber)?.doubleValue
            let percent = total > 0 ? min(1, max(0, downloaded / total)) : 0
            let rate = speed > 0 ? ByteCountFormatter.string(fromByteCount: Int64(min(speed, Double(Int64.max / 2))), countStyle: .file) + "/s" : ""
            let remaining = eta.flatMap { $0.isFinite && $0 >= 0 ? "剩余 \(Int(min($0, 360_000_000))) 秒" : nil } ?? ""
            return .progress(percent, rate, remaining)
        }
        for (prefix, isFile) in [("FLOW_FILE:", true), ("FLOW_TITLE:", false)] where line.hasPrefix(prefix) {
            let raw = String(line.dropFirst(prefix.count))
            let decoded = raw.data(using: .utf8).flatMap { try? JSONDecoder().decode(String.self, from: $0) } ?? raw
            return isFile ? .file(decoded) : .title(decoded)
        }
        return .log(line)
    }
}

/// Owns one subprocess. Cancellation is safe even before Process.run().
public final class EngineProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    public init() {}
    public func cancel() {
        lock.lock(); cancelled = true
        if let process, process.isRunning { process.interrupt() }
        lock.unlock()
    }

    public func run(executable: String, arguments: [String], onLine: @escaping @Sendable (String) -> Void) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let child = Process(), pipe = Pipe()
                child.executableURL = URL(fileURLWithPath: executable)
                child.arguments = arguments
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
                environment["PYTHONUNBUFFERED"] = "1"
                child.environment = environment
                child.standardOutput = pipe; child.standardError = pipe
                child.standardInput = FileHandle.nullDevice
                self.lock.lock()
                if self.cancelled {
                    self.lock.unlock(); continuation.resume(throwing: CancellationError()); return
                }
                self.process = child
                do { try child.run(); self.lock.unlock() }
                catch { self.process = nil; self.lock.unlock(); continuation.resume(throwing: error); return }
                var pending = Data(), tail = ""
                while true {
                    let chunk = pipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 10) {
                        let line = String(decoding: pending[..<newline], as: UTF8.self).trimmingCharacters(in: .newlines)
                        pending.removeSubrange(...newline)
                        onLine(line); tail += line + "\n"
                        if tail.count > 32_768 { tail = String(tail.suffix(24_576)) }
                    }
                    // Metadata can contain a long JSON line. Keep it intact (up to 32 MiB).
                    if pending.count > 32 * 1024 * 1024 {
                        child.terminate(); break
                    }
                }
                if !pending.isEmpty {
                    let line = String(decoding: pending, as: UTF8.self); onLine(line); tail += line
                }
                child.waitUntilExit()
                self.lock.lock(); let wasCancelled = self.cancelled; self.process = nil; self.lock.unlock()
                if wasCancelled { continuation.resume(throwing: CancellationError()) }
                else if child.terminationStatus != 0 {
                    continuation.resume(throwing: InputError.processFailed(String(tail.suffix(6000)).trimmingCharacters(in: .whitespacesAndNewlines)))
                } else { continuation.resume(returning: tail) }
            }
        }
    }
}

public struct DownloadEngine {
    public let paths: EnginePaths
    public init(paths: EnginePaths = EnginePaths()) { self.paths = paths }

    public func commonArguments(browser: String?) -> [String] {
        var args = ["--ignore-config", "--no-playlist", "--playlist-items", "1", "--no-colors", "--socket-timeout", "30", "--retries", "3"]
        if let ffmpeg = paths.ffmpeg { args += ["--ffmpeg-location", ffmpeg] }
        if let runtime = paths.runtime { args += ["--js-runtimes", "deno:" + runtime] }
        if let browser, !browser.isEmpty { args += ["--cookies-from-browser", browser] }
        return args
    }

    public func inspect(_ url: String, browser: String?, process: EngineProcess) async throws -> VideoInfo {
        let validated = try Input.validatedURL(url)
        guard let executable = paths.downloader else { throw InputError.missingEngine }
        let capture = MetadataCapture()
        let output = try await process.run(executable: executable, arguments: commonArguments(browser: browser) + ["--dump-single-json", "--skip-download", "--", validated], onLine: { capture.accept($0) })
        // Warnings may precede JSON on the shared output pipe.
        guard let data = capture.data() else {
            throw InputError.processFailed("未能读取视频信息。\n" + String(output.suffix(2000)))
        }
        return try JSONDecoder().decode(VideoInfo.self, from: data)
    }

    public func arguments(for job: DownloadJob) -> [String] {
        // The UUID directory keeps partial files isolated, so retries can safely resume.
        let work = URL(fileURLWithPath: job.directory).appendingPathComponent(".flow-partials/" + job.id.uuidString).path
        var args = commonArguments(browser: job.cookieBrowser) + [
            "--newline", "--progress", "--no-simulate", "--continue", "--no-overwrites",
            "--progress-template", "download:FLOW_PROGRESS:%(progress)j",
            "--print", "before_dl:FLOW_TITLE:%(title)j", "--print", "after_move:FLOW_FILE:%(filepath)j",
            "-P", "home:" + job.directory, "-P", "temp:" + work,
            "-o", "%(title).160B [%(id)s].%(ext)s", "-f", paths.ffmpeg == nil ? job.quality.singleFileFormat : job.quality.format
        ]
        if job.quality == .audio { args += ["-x", "--audio-format", "mp3", "--audio-quality", "0"] }
        else if paths.ffmpeg != nil { args += ["--merge-output-format", "mp4/mkv"] }
        args += ["--", job.url]
        return args
    }

    public func download(_ job: DownloadJob, process: EngineProcess, onEvent: @escaping @Sendable (EngineEvent) -> Void) async throws {
        _ = try Input.validatedURL(job.url)
        guard let executable = paths.downloader else { throw InputError.missingEngine }
        try FileManager.default.createDirectory(atPath: job.directory, withIntermediateDirectories: true)
        _ = try await process.run(executable: executable, arguments: arguments(for: job)) { line in onEvent(EngineEvent.parse(line)) }
    }
}
