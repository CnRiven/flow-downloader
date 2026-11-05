import Foundation
import FlowCore
import CryptoKit

private struct InstallerCheckFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
private func verify(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw InstallerCheckFailure(message) }
}

private struct FixtureTransport: EngineInstallTransport {
    enum Mode { case valid, badHash, wrongVersion, offsite, traversal, cancelled, disconnected, duplicateHash }
    let mode: Mode
    private let base = "https://github.com/yt-dlp/yt-dlp/releases/download/2026.10.26/"
    private var payload: Data {
        Data(("#!/bin/sh\nprintf '" + (mode == .wrongVersion ? "2025.01.01" : "2026.10.26") + "\\n'\n").utf8)
    }
    func data(from url: URL, maximumBytes: Int) async throws -> Data {
        if url == EngineInstaller.releaseURL {
            return try JSONSerialization.data(withJSONObject: [
                "tag_name": mode == .traversal ? "../../outside" : "2026.10.26",
                "assets": [
                    ["name": "yt-dlp_macos", "size": payload.count, "browser_download_url": mode == .offsite ? "https://example.org/engine" : base + "yt-dlp_macos"],
                    ["name": "SHA2-256SUMS", "size": 100, "browser_download_url": base + "SHA2-256SUMS"]
                ]
            ])
        }
        let hash = mode == .badHash ? String(repeating: "0", count: 64) : SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let line = hash + "  yt-dlp_macos\n"
        return Data((mode == .duplicateHash ? line + line : line).utf8)
    }
    func download(from url: URL, to destination: URL, maximumBytes: Int64,
                  progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try payload.write(to: destination)
        progress(Int64(payload.count), Int64(payload.count))
        if mode == .cancelled { throw CancellationError() }
        if mode == .disconnected { throw URLError(.notConnectedToInternet) }
    }
}

private final class InstallMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    func record(_ value: EngineInstallProgress) { lock.lock(); messages.append(value.message); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return messages }
}

enum InstallerChecks {
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("拾流 installer checks " + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let updates = InstallMessages()
        let result = try await EngineInstaller(transport: FixtureTransport(mode: .valid)).install(to: root) { updates.record($0) }
        try verify(result.version == "2026.10.26", "Installed wrong version")
        try verify(FileManager.default.isExecutableFile(atPath: result.url.path), "Engine not executable")
        let detected = EnginePaths(managedDirectory: root, searchDirectories: [])
        try verify(detected.downloader == result.url.path && detected.ffmpeg == nil && detected.runtime == nil, "Managed engine requires system PATH")
        let version = try await EngineProbe.version(at: result.url.path)
        try verify(version == result.version, "Installed engine cannot run")
        try verify(updates.values.contains("正在校验下载文件…"), "Missing verification progress")
        let oldBinary = try Data(contentsOf: result.url)
        for mode in [FixtureTransport.Mode.badHash, .wrongVersion, .offsite, .traversal, .cancelled, .disconnected, .duplicateHash] {
            do {
                _ = try await EngineInstaller(transport: FixtureTransport(mode: mode)).install(to: root)
                throw InstallerCheckFailure("Installer accepted invalid input: \(mode)")
            } catch is InstallerCheckFailure { throw InstallerCheckFailure("Failed installer did not reject \(mode)") }
            catch {
                if mode == .cancelled { try verify(error is CancellationError, "Cancellation became an installation failure") }
                else {
                    guard let failure = error as? EngineInstallError else { throw error }
                    switch (mode, failure) {
                    case (.badHash, .checksum), (.wrongVersion, .invalidExecutable), (.offsite, .invalidRelease),
                         (.traversal, .invalidRelease), (.duplicateHash, .invalidRelease), (.disconnected, .network): break
                    default: throw InstallerCheckFailure("Wrong failure for \(mode): \(error)")
                    }
                }
            }
            let preserved = try Data(contentsOf: result.url)
            try verify(preserved == oldBinary, "Failed or cancelled install replaced working engine")
            let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
            try verify(!files.contains(where: { $0.hasPrefix(".install-") }), "Failed install left partial files")
        }
        let other = root.appendingPathComponent("system", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let fallback = other.appendingPathComponent("yt-dlp")
        try oldBinary.write(to: fallback); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fallback.path)
        try verify(EnginePaths(managedDirectory: root, searchDirectories: [other.path]).downloader == result.url.path, "System engine overrides managed engine")
        let job = DownloadJob(url: "https://example.org/video.mp4", info: nil, quality: .hd1080, directory: root.path)
        let arguments = DownloadEngine(paths: detected).arguments(for: job)
        try verify(arguments.contains("b[height<=?1080]") && !arguments.contains("bv*[height<=1080]+ba/b[height<=1080]"), "Missing FFmpeg still requests separate tracks")
        print("PASS managed engine installation, checksum/version validation, domain restrictions, rollback, cancellation and PATH discovery")
    }

    static func realInstallation(in root: URL, fixtureURL: String?) async throws {
        let result = try await EngineInstaller().install(to: root)
        let isolated = EnginePaths(managedDirectory: root, searchDirectories: [])
        try verify(isolated.downloader == result.url.path && isolated.ffmpeg == nil, "Installer fell back to Homebrew")
        let version = try await EngineProbe.version(at: result.url.path)
        try verify(version == result.version, "Downloaded standalone engine cannot run")
        print("PASS official standalone yt-dlp installed and verified: \(version)")
        if let fixtureURL {
            let engine = DownloadEngine(paths: isolated)
            let info = try await engine.inspect(fixtureURL, browser: nil, process: EngineProcess())
            let job = DownloadJob(url: fixtureURL, info: info, quality: .hd1080, directory: root.appendingPathComponent("Downloads").path)
            _ = try await engine.download(job, process: EngineProcess(), onEvent: { _ in })
            let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: job.directory), includingPropertiesForKeys: nil)
            try verify(files.contains(where: { $0.pathExtension == "mp4" }), "Managed engine did not download fixture without FFmpeg")
            print("PASS automatically installed standalone engine: real metadata and video download with empty system search paths")
        }
    }
}
