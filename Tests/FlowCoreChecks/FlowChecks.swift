import Foundation
import FlowCore

private struct CheckError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckError(message) }
}
private func unwrap<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw CheckError(message) }; return value
}
private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [EngineEvent] = []
    func append(_ event: EngineEvent) { lock.lock(); storage.append(event); lock.unlock() }
    var values: [EngineEvent] { lock.lock(); defer { lock.unlock() }; return storage }
}

/// Standalone checks also work with Apple's Command Line Tools, without Xcode/XCTest.
@main struct FlowChecks {
    static func main() async throws {
        try validationAndArguments(); print("PASS URL validation and argument safety")
        try await ShareChecks.run()
        try structuredEvents(); print("PASS structured progress and Unicode paths")
        try ProgressChecks.run()
        try historyRecovery(); print("PASS history recovery and corruption handling")
        try await metadataAndFailure(); print("PASS large metadata and subprocess failure")
        try await cancellation(); print("PASS cancellation before launch and while running")
        try await InstallerChecks.run()
        if let url = ProcessInfo.processInfo.environment["FLOW_INTEGRATION_URL"] {
            try await realDownload(url); print("PASS real yt-dlp video download and FFmpeg MP3 conversion")
            try await selectedWebVideo(url); print("PASS selected webpage metadata download through real yt-dlp")
        }
        if let url = ProcessInfo.processInfo.environment["FLOW_MULTI_TRACK_URL"] {
            try await multiTrackDownload(url); print("PASS real DASH video/audio download, monotonic overall progress and final merge")
        }
        if let url = ProcessInfo.processInfo.environment["FLOW_RESUME_URL"], let fixture = ProcessInfo.processInfo.environment["FLOW_RESUME_FIXTURE"] {
            try await realResume(url, fixture: fixture); print("PASS real download interruption and HTTP Range resume, byte-for-byte output")
        }
        if let directory = ProcessInfo.processInfo.environment["FLOW_REAL_ENGINE_INSTALL_ROOT"] {
            try await InstallerChecks.realInstallation(in: URL(fileURLWithPath: directory), fixtureURL: ProcessInfo.processInfo.environment["FLOW_INTEGRATION_URL"])
        }
        print("All checks passed.")
    }

    static func validationAndArguments() throws {
        for value in ["file:///etc/passwd", "--exec=touch /tmp/a", "https://", "https://a.com\n--exec=hi", "hello"] {
            do { _ = try Input.validatedURL(value); throw CheckError("Accepted unsafe URL: " + value) }
            catch is InputError { }
        }
        let url = "https://example.com/watch?v=$(touch%20/tmp/flow)&x=1"
        let validated = try Input.validatedURL(url)
        try expect(validated == url, "Changed valid URL")
        let job = DownloadJob(url: url, info: nil, quality: .hd1080, directory: "/tmp/My Videos")
        let args = DownloadEngine(paths: EnginePaths(downloader: "/fake")).arguments(for: job)
        try expect(Array(args.suffix(2)) == ["--", url], "URL must be a single argument after --")
        try expect(args.contains("home:/tmp/My Videos"), "Directory with spaces split")
        try expect(args.contains("--ignore-config"), "External config not disabled")
    }

    static func structuredEvents() throws {
        let event = EngineEvent.parse("FLOW_PROGRESS:{\"status\":\"downloading\",\"downloaded_bytes\":50,\"total_bytes\":100,\"speed\":1024,\"eta\":7}")
        guard case .progress(let progress, let speed, let eta) = event else { throw CheckError("Missing progress") }
        try expect(progress == 0.5 && !speed.isEmpty && eta == "剩余 7 秒", "Incorrect progress values")
        try expect(EngineEvent.parse("FLOW_PROGRESS:{\"status\":\"finished\"}") == .processing, "Finished fragment is not final completion")
        try expect(EngineEvent.parse("FLOW_FILE:\"/tmp/视频 [id].mp4\"") == .file("/tmp/视频 [id].mp4"), "Unicode path lost")
        try expect(EngineEvent.parse("FLOW_PROGRESS:{broken}") == .log("FLOW_PROGRESS:{broken}"), "Malformed event not preserved")
    }

    static func historyRecovery() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("history.json")
        var job = DownloadJob(url: "https://example.com", info: nil, quality: .best, directory: dir.path)
        job.status = .downloading; job.progress = 0.45
        try JobHistory.save([job], to: file)
        let recovered = try unwrap(try JobHistory.load(from: file).first, "Missing recovered job")
        try expect(recovered.status == .paused && recovered.progress == 0.45, "Recovery lost progress")
        try Data("corrupt".utf8).write(to: file)
        do { _ = try JobHistory.load(from: file); throw CheckError("Corruption silently discarded") }
        catch is DecodingError { }
    }

    static func metadataAndFailure() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("engine")
        let json = "{\"title\":\"长元数据\",\"description\":\"" + String(repeating: "x", count: 100_000) + "\"}"
        try Data(("#!/bin/sh\ncat <<'FLOW_JSON'\n" + json + "\nFLOW_JSON\n").utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let engine = DownloadEngine(paths: EnginePaths(downloader: script.path))
        let info = try await engine.inspect("https://example.com", browser: nil, process: EngineProcess())
        try expect(info.title == "长元数据", "Large metadata truncated")
        do {
            _ = try await EngineProcess().run(executable: "/bin/sh", arguments: ["-c", "echo expected-error; exit 2"], onLine: { _ in })
            throw CheckError("Nonzero exit not propagated")
        } catch let error as InputError { try expect(error.localizedDescription.contains("expected-error"), "Error output lost") }
    }

    static func cancellation() async throws {
        let cancelled = EngineProcess(); cancelled.cancel()
        do { _ = try await cancelled.run(executable: "/bin/sleep", arguments: ["20"], onLine: { _ in }); throw CheckError("Cancelled process launched") }
        catch is CancellationError { }
        let running = EngineProcess()
        let task = Task { try await running.run(executable: "/bin/sleep", arguments: ["20"], onLine: { _ in }) }
        try await Task.sleep(nanoseconds: 150_000_000); running.cancel()
        do { _ = try await task.value; throw CheckError("Running process not cancelled") }
        catch is CancellationError { }
    }

    static func realDownload(_ url: String) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Flow integration " + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = DownloadEngine()
        let info = try await engine.inspect(url, browser: nil, process: EngineProcess())
        try expect(!info.title.isEmpty, "Real metadata missing")
        for quality in [Quality.best, .audio] {
            let events = Events(), job = DownloadJob(url: url, info: info, quality: quality, directory: dir.path)
            try await engine.download(job, process: EngineProcess()) { events.append($0) }
            let file = try unwrap(events.values.compactMap { event -> String? in if case .file(let path) = event { return path }; return nil }.last, "No after_move output path")
            try expect(FileManager.default.fileExists(atPath: file), "Output file missing")
            let size = (try FileManager.default.attributesOfItem(atPath: file)[.size] as? Int) ?? 0
            try expect(size > 0, "Empty output file")
            if quality == .audio { try expect(file.hasSuffix(".mp3"), "FFmpeg did not produce MP3") }
        }
    }

    static func realResume(_ url: String, fixture: String) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Flow resume " + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = DownloadEngine(), process = EngineProcess()
        let job = DownloadJob(url: url, info: nil, quality: .best, directory: dir.path)
        do {
            try await engine.download(job, process: process) { event in
                if case .progress(let progress, _, _) = event, progress >= 0.03 { process.cancel() }
            }
            throw CheckError("Interrupted download unexpectedly completed")
        } catch is CancellationError { }
        let partials = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        try expect(partials.contains { $0.pathExtension == "part" }, "Cancellation did not preserve partial file")
        let events = Events()
        try await engine.download(job, process: EngineProcess()) { events.append($0) }
        let path = try unwrap(events.values.compactMap { event -> String? in if case .file(let path) = event { return path }; return nil }.last, "Resumed download missing output")
        let actual = try Data(contentsOf: URL(fileURLWithPath: path)), expected = try Data(contentsOf: URL(fileURLWithPath: fixture))
        try expect(actual == expected, "Resumed file differs from source bytes")
    }

    static func multiTrackDownload(_ url: String) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Flow multi-track " + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let events = Events(), job = DownloadJob(url: url, info: nil, quality: .best, directory: dir.path)
        try await DownloadEngine().download(job, process: EngineProcess()) { events.append($0) }
        let values = events.values.compactMap { event -> Double? in if case .progress(let value, _, _) = event { return value }; return nil }
        try expect(!values.isEmpty && zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }, "Real DASH progress regressed")
        try expect(values.allSatisfy { $0 < 1 } && values.contains { $0 > 0 && $0 < 0.95 }, "Real tracks were not aggregated")
        try expect(events.values.filter { $0 == .processing }.count == 1, "Individual track completion was mistaken for merging")
        let path = try unwrap(events.values.compactMap { event -> String? in if case .file(let path) = event { return path }; return nil }.last, "Merged output missing")
        try expect(FileManager.default.fileExists(atPath: path), "Merged file missing")
    }

    static func selectedWebVideo(_ url: String) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Flow selected video " + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = "https://www.douyin.com/video/123456789"
        let metadata: [String: Any] = ["id": "123456789", "title": "Selected test video", "extractor": "webpage", "webpage_url": source,
                                      "formats": [["format_id": "web", "url": url, "ext": "mp4", "vcodec": "unknown", "acodec": "unknown"]]]
        let file = dir.appendingPathComponent("selected.json")
        try JSONSerialization.data(withJSONObject: metadata).write(to: file)
        let access = DouyinAccess(source: source, cookieFile: nil, infoFile: file)
        let events = Events(), job = DownloadJob(url: source, info: nil, quality: .hd1080, directory: dir.path)
        try await DownloadEngine().download(job, process: EngineProcess(), access: access) { events.append($0) }
        let output = try unwrap(events.values.compactMap { event -> String? in if case .file(let path) = event { return path }; return nil }.last, "Selected video output missing")
        try expect(FileManager.default.fileExists(atPath: output), "Selected webpage video was not saved")
    }
}
