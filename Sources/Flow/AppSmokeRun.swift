import Foundation
import AppKit
import FlowCore

/// Opt-in UI check with isolated storage and no system executable search paths.
@MainActor enum AppSmokeRun {
    static var root: URL? {
        guard let index = CommandLine.arguments.firstIndex(of: "--smoke-test-root"), CommandLine.arguments.count > index + 1 else { return nil }
        return URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
    }
    private static var fixture: String? {
        guard let index = CommandLine.arguments.firstIndex(of: "--smoke-fixture-url"), CommandLine.arguments.count > index + 1 else { return nil }
        return CommandLine.arguments[index + 1]
    }
    private static func wait(seconds: Double, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { throw InputError.processFailed("UI smoke check timed out") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
    private static func capture(_ destination: URL) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }),
              let view = (window.attachedSheet ?? window).contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: destination)
    }
    static func run(_ model: AppModel) async {
        guard let root, let fixture else { return }
        var report: [String: Any] = [:]
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            report["alreadyInstalled"] = model.paths.downloader != nil
            report["isolatedSystemPaths"] = model.paths.ffmpeg == nil && model.paths.runtime == nil
            let previousIDs = Set(model.jobs.map(\.id))
            model.urlInput = fixture; model.showingNew = true
            model.inspect() // This must install a missing engine and then continue the original request.
            Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                capture(root.appendingPathComponent("first-launch.png"))
            }
            if CommandLine.arguments.contains("--smoke-enqueue-during-parse") {
                for _ in 0..<20 { model.inspect() }
                try await Task.sleep(nanoseconds: 500_000_000)
                capture(root.appendingPathComponent("parsing.png"))
                let start = Date()
                for _ in 0..<20 { model.add() }
                report["enqueueMilliseconds"] = Date().timeIntervalSince(start) * 1000
                guard !model.showingNew, !model.inspecting,
                      model.jobs.filter({ !previousIDs.contains($0.id) }).count == 1 else {
                    throw InputError.processFailed("Repeated clicks duplicated or delayed submission")
                }
                capture(root.appendingPathComponent("queued.png"))
            } else {
                try await wait(seconds: 360) { !model.inspecting }
                if let error = model.engineSetupError ?? model.error { throw InputError.processFailed(error) }
                guard let info = model.info else { throw InputError.processFailed("Missing parsed metadata") }
                report["title"] = info.title
                for _ in 0..<20 { model.inspect() }
                guard !model.inspecting else { throw InputError.processFailed("Cached metadata was requested again") }
                model.quality = .hd1080; model.add()
            }
            var observed: [Double] = []
            try await wait(seconds: 360) {
                if let job = model.jobs.first(where: { !previousIDs.contains($0.id) }) { observed.append(job.progress) }
                return !model.hasActiveProcesses
            }
            guard zip(observed, observed.dropFirst()).allSatisfy({ $0 <= $1 }) else {
                throw InputError.processFailed("Visible progress regressed")
            }
            report["progressSamples"] = observed
            guard let installed = model.paths.downloader,
                  installed.hasPrefix(root.path), !model.engineVersion.isEmpty else { throw InputError.missingEngine }
            report["engine"] = installed; report["version"] = model.engineVersion
            guard let job = model.jobs.first(where: { !previousIDs.contains($0.id) }), job.status == .completed, let file = job.filePath,
                  FileManager.default.fileExists(atPath: file) else {
                throw InputError.processFailed(model.jobs.first?.error ?? model.error ?? "Missing smoke-check output")
            }
            report["output"] = file; report["status"] = "passed"
            try await Task.sleep(nanoseconds: 350_000_000)
            capture(root.appendingPathComponent("completed.png"))
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription
            capture(root.appendingPathComponent("failed.png"))
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: root.appendingPathComponent("result.json"), options: .atomic)
        }
        model.shutdown(); NSApp.terminate(nil)
    }
}
