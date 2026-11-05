import AppKit
import SwiftUI
import FlowCore

@MainActor
final class AppModel: ObservableObject {
    @Published var jobs: [DownloadJob] = []
    @Published var urlInput = "" { didSet { if oldValue != urlInput { invalidatePreview() } } }
    @Published var info: VideoInfo?
    @Published var inspecting = false
    @Published var quality = Quality.hd1080
    @Published var directory: String
    @Published var browser: String { didSet { UserDefaults.standard.set(browser, forKey: "cookieBrowser"); invalidatePreview() } }
    @Published var error: String?
    @Published var paths = EnginePaths()
    @Published var selectedSection = "全部任务"
    @Published var search = ""
    @Published var showingNew = false
    @Published var showingSettings = false
    @Published var logJob: DownloadJob?
    @Published var logs: [UUID: [String]] = [:]
    private var workers: [UUID: EngineProcess] = [:]
    private var inspection: EngineProcess?
    private var inspectionToken = UUID()
    private var inspectedURL: String?
    private let historyURL: URL
    private var quitting = false

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Flow")
        historyURL = support.appendingPathComponent("history.json")
        directory = UserDefaults.standard.string(forKey: "downloadDirectory") ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("拾流").path
        browser = UserDefaults.standard.string(forKey: "cookieBrowser") ?? ""
        do { jobs = try JobHistory.load(from: historyURL) }
        catch {
            let backup = support.appendingPathComponent("history-corrupt-\(Int(Date().timeIntervalSince1970)).json")
            do {
                try FileManager.default.copyItem(at: historyURL, to: backup)
                self.error = "历史记录读取失败，原始数据已备份至：\(backup.path)"
            } catch {
                self.error = "历史记录读取或备份失败，请检查此文件：\(historyURL.path)"
            }
        }
    }

    var filteredJobs: [DownloadJob] {
        jobs.filter { job in
            let matches = selectedSection == "全部任务" || (selectedSection == "下载中" && [.queued, .downloading, .processing, .paused].contains(job.status)) || (selectedSection == "已完成" && job.status == .completed)
            return matches && (search.isEmpty || job.title.localizedCaseInsensitiveContains(search) || job.url.localizedCaseInsensitiveContains(search))
        }
    }
    var activeCount: Int { jobs.filter { [.queued, .downloading, .processing].contains($0.status) }.count }
    var completedCount: Int { jobs.filter { $0.status == .completed }.count }
    var pausedCount: Int { jobs.filter { $0.status == .paused }.count }
    var hasActiveProcesses: Bool { !workers.isEmpty || inspecting }

    private func invalidatePreview() {
        inspectionToken = UUID(); inspection?.cancel(); inspection = nil
        inspecting = false; info = nil; inspectedURL = nil
    }

    func inspect() {
        do {
            let url = try Input.validatedURL(urlInput)
            inspection?.cancel()
            let process = EngineProcess(), token = UUID(), cookie = browser.isEmpty ? nil : browser
            inspectionToken = token; inspection = process; inspecting = true; error = nil; info = nil
            let engine = DownloadEngine(paths: paths)
            Task { [self] in
                do {
                    let result = try await engine.inspect(url, browser: cookie, process: process)
                    guard token == inspectionToken else { return }
                    info = result; inspectedURL = url
                } catch is CancellationError { }
                catch { if token == inspectionToken { self.error = error.localizedDescription } }
                if token == inspectionToken { inspecting = false; inspection = nil }
            }
        } catch { self.error = error.localizedDescription }
    }

    func add() {
        do {
            let url = try Input.validatedURL(urlInput)
            guard paths.downloader != nil else { throw InputError.missingEngine }
            if quality == .audio && paths.ffmpeg == nil { throw InputError.processFailed("提取 MP3 需要 FFmpeg，请先在设置中安装。") }
            let job = DownloadJob(url: url, info: inspectedURL == url ? info : nil, quality: quality, directory: directory, cookieBrowser: browser.isEmpty ? nil : browser)
            jobs.insert(job, at: 0); persist(); showingNew = false; urlInput = ""; error = nil
            pump()
        } catch { self.error = error.localizedDescription }
    }

    func pasteLink() {
        if let value = NSPasteboard.general.string(forType: .string) { urlInput = value.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "选择下载位置"
        if panel.runModal() == .OK, let url = panel.url {
            directory = url.path; UserDefaults.standard.set(directory, forKey: "downloadDirectory")
        }
    }

    func pause(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].status.active || jobs[index].status == .queued else { return }
        jobs[index].status = .paused; workers[id]?.cancel(); persist()
    }

    func resume(_ id: UUID) {
        guard workers[id] == nil else { return }
        edit(id) { $0.status = .queued; $0.error = nil; $0.speed = ""; $0.eta = "" }
        pump()
    }

    func remove(_ id: UUID) {
        let job = jobs.first { $0.id == id }
        workers[id]?.cancel(); jobs.removeAll { $0.id == id }; logs[id] = nil; persist()
        if workers[id] == nil, let job { cleanPartials(job) }
    }

    func reveal(_ job: DownloadJob) {
        if let file = job.filePath, FileManager.default.fileExists(atPath: file) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)])
        } else { NSWorkspace.shared.open(URL(fileURLWithPath: job.directory)) }
    }

    func refreshEngine() { paths = EnginePaths() }

    func shutdown() {
        quitting = true; inspection?.cancel()
        for id in Array(workers.keys) { pause(id) }
        persist()
    }

    private func edit(_ id: UUID, _ change: (inout DownloadJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index]); persist()
    }

    private func persist() {
        do { try JobHistory.save(jobs, to: historyURL) }
        catch { self.error = "无法保存任务记录：" + error.localizedDescription }
    }

    private func pump() {
        guard !quitting else { return }
        while workers.count < 2, let job = jobs.first(where: { $0.status == .queued && workers[$0.id] == nil }) {
            let process = EngineProcess(), engine = DownloadEngine(paths: paths), id = job.id
            workers[id] = process; edit(id) { $0.status = .downloading }
            Task { [self] in
                do {
                    try await engine.download(job, process: process) { [weak self] event in
                        // Enqueue events serially on the main queue before the completion below.
                        DispatchQueue.main.async { self?.handle(event, id: id) }
                    }
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        DispatchQueue.main.async { continuation.resume() }
                    }
                    if let current = jobs.first(where: { $0.id == id }), current.status != .paused {
                        if let file = current.filePath, FileManager.default.fileExists(atPath: file) {
                            edit(id) { $0.status = .completed; $0.progress = 1; $0.speed = ""; $0.eta = "" }
                        } else { throw InputError.missingOutput }
                    }
                } catch is CancellationError { }
                catch {
                    if jobs.first(where: { $0.id == id })?.status != .paused {
                        edit(id) { $0.status = .failed; $0.error = error.localizedDescription }
                    }
                }
                workers[id] = nil
                if jobs.first(where: { $0.id == id }) == nil || jobs.first(where: { $0.id == id })?.status == .completed { cleanPartials(job) }
                pump()
            }
        }
    }

    private func handle(_ event: EngineEvent, id: UUID) {
        guard let current = jobs.first(where: { $0.id == id }), current.status != .paused else { return }
        switch event {
        case .progress(let progress, let speed, let eta): edit(id) { $0.progress = progress; $0.speed = speed; $0.eta = eta; $0.status = .downloading }
        case .processing: edit(id) { $0.status = .processing }
        case .title(let title): edit(id) { $0.title = title }
        case .file(let file): edit(id) { $0.filePath = file }
        case .log(let line):
            var lines = logs[id] ?? []; lines.append(line)
            logs[id] = Array(lines.suffix(150))
        }
    }

    private func cleanPartials(_ job: DownloadJob) {
        let folder = URL(fileURLWithPath: job.directory).appendingPathComponent(".flow-partials/" + job.id.uuidString)
        try? FileManager.default.removeItem(at: folder)
    }
}
