import Foundation
import FlowCore
import WebKit

@main @MainActor struct ModelChecks {
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw InputError.processFailed(message) }
    }
    static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition() {
            guard Date() < deadline else { throw InputError.processFailed("Model check timed out") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Flow interactions " + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = root.appendingPathComponent("calls")
        let script = root.appendingPathComponent("engine")
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let engine = """
        #!/bin/sh
        calls=\(quote(calls.path))
        if [ "$1" = '--version' ]; then
          echo version >> "$calls"
          /bin/sleep 0.3
          echo 2026.10.26
          exit 0
        fi
        mode=download
        for arg in "$@"; do
          if [ "$arg" = '--dump-single-json' ]; then mode=inspect; fi
          case "$arg" in home:*) directory="${arg#home:}" ;; esac
          last="$arg"
        done
        echo "$mode" >> "$calls"
        if [ "$last" = 'https://www.douyin.com/video/111' ]; then
          echo 'ERROR: Fresh cookies are needed' >&2
          exit 2
        fi
        if [ "$mode" = inspect ]; then
          /bin/sleep 0.6
          printf '{"title":"%s"}\\n' "$last"
        else
          /bin/mkdir -p "$directory"
          echo 'FLOW_PLAN:[{"format_id":"video","filesize":900},{"format_id":"audio","filesize":100}]'
          echo 'FLOW_TITLE:"Interaction test"'
          echo 'FLOW_PROGRESS:{"format_id":"video","progress":{"status":"downloading","downloaded_bytes":450,"total_bytes":900}}'
          /bin/sleep 0.15
          echo 'FLOW_PROGRESS:{"format_id":"video","progress":{"status":"downloading","downloaded_bytes":450,"total_bytes_estimate":1800}}'
          echo 'FLOW_PROGRESS:{"format_id":"video","progress":{"status":"finished"}}'
          /bin/sleep 0.15
          echo 'FLOW_PROGRESS:{"format_id":"audio","progress":{"status":"downloading","downloaded_bytes":1,"total_bytes":100}}'
          /bin/sleep 0.15
          echo 'FLOW_PROGRESS:{"format_id":"audio","progress":{"status":"finished"}}'
          echo FLOW_PROCESSING
          /bin/sleep 0.15
          echo test > "$directory/result.mp4"
          printf 'FLOW_FILE:"%s/result.mp4"\\n' "$directory"
        fi
        """
        try Data(engine.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let suite = "app.flow.checks." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        func model(_ name: String) -> AppModel {
            AppModel(locatePaths: { EnginePaths(downloader: script.path) }, storageDirectory: root.appendingPathComponent(name), preferences: preferences)
        }
        func count(_ value: String) -> Int {
            ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0 == value }.count
        }

        let app = model("primary")
        defer { app.shutdown() }
        app.showingNew = true; app.urlInput = "https://fixture/preview"
        for _ in 0..<20 { app.inspect() }
        try expect(app.inspecting && app.inspectionStartedAt != nil && !app.canInspect, "Parsing did not immediately enter busy state")
        try await wait { !app.inspecting }
        try expect(app.hasPreview && app.info?.title == "https://fixture/preview", "Preview was not retained")
        for _ in 0..<20 { app.inspect() }
        try expect(count("inspect") == 1 && count("version") == 1, "Repeated parse launched duplicate subprocesses")
        print("PASS parse busy feedback, click deduplication and cached preview reuse")

        app.urlInput = "https://fixture/cancelled"; app.inspect()
        try await wait { count("inspect") == 2 }
        app.urlInput = "https://fixture/current"; app.inspect()
        try await wait { !app.inspecting }
        try expect(app.info?.title == "https://fixture/current", "Cancelled metadata overwrote the current URL")
        app.urlInput = "https://fixture/manual-cancel"; app.inspect(); app.cancelInspection()
        try expect(!app.inspecting && app.inspectionStartedAt == nil && app.info == nil, "Cancel did not immediately release the UI")
        print("PASS input changes and explicit cancellation discard stale parsing results")

        app.urlInput = "https://fixture/queued-during-parse"; app.inspect()
        let start = Date()
        for _ in 0..<20 { app.add() }
        try expect(Date().timeIntervalSince(start) < 0.2, "Queue submission waited on a subprocess")
        try expect(app.jobs.count == 1 && !app.showingNew && !app.inspecting && app.urlInput.isEmpty, "Queue submission was not immediate or duplicated")
        app.showingNew = true; app.urlInput = "https://fixture/queued-during-parse"; app.add()
        try expect(app.jobs.count == 1 && app.notice?.contains("无需重复") == true, "Duplicate active job was enqueued")
        var observed: [Double] = []
        while app.hasActiveProcesses {
            observed.append(app.jobs[0].progress)
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try expect(app.jobs[0].status == .completed && app.jobs[0].progress == 1, "Queued job did not complete")
        try expect(zip(observed, observed.dropFirst()).allSatisfy { $0 <= $1 }, "Visible app progress regressed")
        try expect(observed.filter { $0 > 0 && $0 < 1 }.allSatisfy { $0 <= 0.95 }, "App showed completion before output existed")
        try expect(count("download") == 1 && count("version") == 1, "Submission repeated extraction or engine probing")
        let saved = try JobHistory.load(from: root.appendingPathComponent("primary/history.json"))
        try expect(saved.first?.status == .completed, "Final history was not flushed")
        print("PASS immediate enqueue during parsing, duplicate prevention, monotonic UI progress and final history")

        let delayed = model("delayed")
        defer { delayed.shutdown() }
        delayed.showingNew = true; delayed.urlInput = "https://fixture/delayed"; delayed.add()
        try expect(delayed.jobs.count == 1 && delayed.jobs[0].status == .queued, "Unprobed engine delayed queue creation")
        let id = delayed.jobs[0].id
        delayed.pause(id)
        try await wait { !delayed.hasActiveProcesses }
        try expect(delayed.jobs[0].status == .paused && count("download") == 1, "Paused waiting task started after engine preparation")
        for _ in 0..<20 { delayed.resume(id) }
        try await wait { !delayed.hasActiveProcesses }
        try expect(delayed.jobs[0].status == .completed && count("download") == 2, "Repeated resume duplicated work")
        print("PASS background engine preparation, pause while waiting and repeated resume")
        app.showingNew = true; app.urlInput = "分享文案 https://www.douyin.com/video/111 复制打开抖音"; app.inspect()
        try await wait { !app.inspecting }
        try expect(app.loginRequiredURL == "https://www.douyin.com/video/111" && app.error?.contains("抖音登录 / 验证") == true, "Fresh cookie failure did not offer native login recovery")
        print("PASS missing Douyin session produces login recovery for share-text inspection")
        let session = delayed.douyinSession
        let cookie = HTTPCookie(properties: [.domain: ".douyin.com", .path: "/", .name: "sessionid", .value: "flow-test-session", .secure: "TRUE"])!
        let unrelated = HTTPCookie(properties: [.domain: ".example.com", .path: "/", .name: "sessionid", .value: "unrelated-test-session"])!
        for value in [cookie, unrelated] {
            await withCheckedContinuation { continuation in session.store.httpCookieStore.setCookie(value) { continuation.resume() } }
        }
        try await session.save()
        let source = "https://www.douyin.com/video/123456789"
        try session.remember(.init(source: source, url: "https://test.douyinvod.com/video/test.mp4", title: "Selected test video", duration: 12, savedAt: Date()))
        var prepared: PreparedWebAccess? = try await session.prepare(source)
        guard let cookieURL = prepared?.access.cookieFile, let infoURL = prepared?.access.infoFile else { throw InputError.processFailed("Saved WebKit state was not exported") }
        let exported = try String(contentsOf: cookieURL, encoding: .utf8)
        try expect(exported.contains("flow-test-session") && !exported.contains("unrelated-test-session"), "WebKit cookie export crossed site boundary")
        let mode = try FileManager.default.attributesOfItem(atPath: cookieURL.path)[.posixPermissions] as? NSNumber
        try expect(mode?.intValue == 0o600, "Cookie file is not private")
        try expect(prepared?.access.preview?.title == "Selected test video", "Explicit selected video preview missing")
        let other = try await session.prepare("https://example.com/video")
        try expect(other == nil, "Session applied to unrelated download")
        prepared = nil
        try expect(!FileManager.default.fileExists(atPath: cookieURL.path) && !FileManager.default.fileExists(atPath: infoURL.path), "Temporary session files survived request cleanup")
        await session.clear()
        try expect(!session.enabled, "Clearing WebKit did not revoke engine access")
        let cleared = try await session.prepare(source)
        try expect(cleared == nil, "Cleared captured video was still available")
        print("PASS real isolated WebKit cookie export, explicit video selection, file permissions, cleanup and clearing")
        print("All macOS interaction checks passed.")
    }
}
