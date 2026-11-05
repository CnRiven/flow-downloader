import Foundation
import FlowCore

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
        print("All macOS interaction checks passed.")
    }
}
