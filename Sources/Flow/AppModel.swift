import AppKit
import SwiftUI
import FlowCore

@MainActor
final class AppModel: ObservableObject {
    @Published var jobs: [DownloadJob] = []
    @Published var urlInput = "" { didSet { if oldValue != urlInput { submittedDraft = false; invalidatePreview() } } }
    @Published var info: VideoInfo?
    @Published var inspecting = false
    @Published private(set) var inspectionStartedAt: Date?
    @Published private(set) var notice: String?
    @Published var enginePreparing = false
    @Published var engineProgress: EngineInstallProgress?
    @Published var engineSetupError: String?
    @Published var engineVersion = ""
    @Published var quality = Quality.hd1080
    @Published var directory: String
    @Published var browser: String { didSet { preferences.set(browser, forKey: "cookieBrowser"); invalidatePreview() } }
    @Published var error: String?
    @Published var paths = EnginePaths()
    @Published var selectedSection = "全部任务"
    @Published var search = ""
    @Published var showingNew = false { didSet { if showingNew && !oldValue { submittedDraft = false } } }
    @Published var showingSettings = false
    @Published var logJob: DownloadJob?
    @Published var logs: [UUID: [String]] = [:]
    private var workers: [UUID: EngineProcess] = [:]
    private var inspection: EngineProcess?
    private var inspectionToken = UUID()
    private var inspectedURL: String?
    private let locatePaths: () -> EnginePaths
    private let managedDirectory: URL
    private let preferences: UserDefaults
    private var confirmedEngine: String?
    private var preparationTask: Task<Bool, Never>?
    private var preparationID = UUID()
    private var startedPreparation = false
    private var submittedDraft = false
    private var queuePreparation: Task<Void, Never>?
    private var progressSave: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private let historyURL: URL
    private var quitting = false

    init(managedDirectory: URL = EnginePaths.managedBinDirectory, locatePaths: @escaping () -> EnginePaths = { EnginePaths() },
         storageDirectory: URL? = nil, preferences: UserDefaults = .standard) {
        self.managedDirectory = managedDirectory; self.locatePaths = locatePaths
        self.preferences = preferences
        paths = locatePaths()
        let support = storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Flow")
        historyURL = support.appendingPathComponent("history.json")
        directory = preferences.string(forKey: "downloadDirectory") ?? (storageDirectory?.appendingPathComponent("Downloads") ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("拾流")).path
        browser = preferences.string(forKey: "cookieBrowser") ?? ""
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
            let matches = selectedSection == "全部任务" || (selectedSection == "下载中" && (job.status.active || [.queued, .paused].contains(job.status))) || (selectedSection == "已完成" && job.status == .completed)
            return matches && (search.isEmpty || job.title.localizedCaseInsensitiveContains(search) || job.url.localizedCaseInsensitiveContains(search))
        }
    }
    var activeCount: Int { jobs.filter { $0.status.active || $0.status == .queued }.count }
    var completedCount: Int { jobs.filter { $0.status == .completed }.count }
    var pausedCount: Int { jobs.filter { $0.status == .paused }.count }
    var hasActiveProcesses: Bool { !workers.isEmpty || inspecting || enginePreparing || queuePreparation != nil }
    var hasPreview: Bool { info != nil && inspectedURL == (try? Input.validatedURL(urlInput)) }
    var canInspect: Bool { !inspecting && !hasPreview && !urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var inspectButtonTitle: String { inspecting ? "解析中…" : (hasPreview ? "已解析" : "解析") }

    func startEnginePreparation() {
        guard !startedPreparation else { return }; startedPreparation = true
        Task { _ = await prepareEngine() }
    }

    func retryEngineInstallation() { Task { _ = await prepareEngine(forceInstall: true) } }

    func cancelEngineInstallation() { preparationTask?.cancel() }

    @discardableResult
    func prepareEngine(forceInstall: Bool = false) async -> Bool {
        if let task = preparationTask { return await task.value }
        paths = locatePaths()
        if !forceInstall, let path = paths.downloader, confirmedEngine == path { return true }
        let id = UUID(); preparationID = id
        enginePreparing = true; engineSetupError = nil
        engineProgress = EngineInstallProgress("正在检查下载引擎…")
        let task = Task { [self] in
            defer { if preparationID == id { preparationTask = nil; enginePreparing = false } }
            do {
                if !forceInstall, let path = paths.downloader {
                    do {
                        let version = try await EngineProbe.version(at: path)
                        try Task.checkCancellation()
                        confirmedEngine = path; engineVersion = version; return true
                    } catch is CancellationError { throw CancellationError() }
                    catch { try Task.checkCancellation() } // Broken installations are replaced only in Flow's own directory.
                }
                let installed = try await EngineInstaller().install(to: managedDirectory) { [weak self] update in
                    Task { @MainActor in
                        guard let self, self.preparationID == id else { return }
                        if let next = update.fraction, let previous = self.engineProgress?.fraction, next < previous { return }
                        self.engineProgress = update
                    }
                }
                try Task.checkCancellation()
                paths = locatePaths(); confirmedEngine = installed.url.path; engineVersion = installed.version
                return true
            } catch is CancellationError {
                if preparationID == id { engineSetupError = "安装已取消，可以点击重试。" }
            } catch {
                if preparationID == id { engineSetupError = error.localizedDescription }
            }
            return false
        }
        preparationTask = task
        return await task.value
    }

    private func invalidatePreview() {
        inspectionToken = UUID(); inspection?.cancel(); inspection = nil
        inspecting = false; inspectionStartedAt = nil; info = nil; inspectedURL = nil
    }

    func cancelInspection() { invalidatePreview() }

    func inspect() {
        guard !inspecting else { return }
        do {
            let url = try Input.validatedURL(urlInput)
            guard !(inspectedURL == url && info != nil) else { return }
            inspection?.cancel()
            let process = EngineProcess(), token = UUID(), cookie = browser.isEmpty ? nil : browser
            inspectionToken = token; inspection = process; inspecting = true; inspectionStartedAt = Date(); error = nil; info = nil
            Task { [self] in
                do {
                    guard token == inspectionToken else { return }
                    guard await prepareEngine(), token == inspectionToken else { finishInspection(token); return }
                    let engine = DownloadEngine(paths: paths)
                    let result = try await engine.inspect(url, browser: cookie, process: process)
                    guard token == inspectionToken else { return }
                    info = result; inspectedURL = url
                } catch is CancellationError { }
                catch { if token == inspectionToken { self.error = error.localizedDescription } }
                finishInspection(token)
            }
        } catch { self.error = error.localizedDescription }
    }

    private func finishInspection(_ token: UUID) {
        guard token == inspectionToken else { return }
        inspecting = false; inspection = nil; inspectionStartedAt = nil
    }

    func add() {
        guard !submittedDraft else { return }
        do {
            let url = try Input.validatedURL(urlInput)
            paths = locatePaths()
            if quality == .audio && paths.ffmpeg == nil {
                error = "提取 MP3 需要 FFmpeg，请在偏好设置中安装可选组件。"; return
            }
            let job = DownloadJob(url: url, info: inspectedURL == url ? info : nil, quality: quality, directory: directory, cookieBrowser: browser.isEmpty ? nil : browser)
            let duplicate = jobs.first {
                ($0.status.active || [.queued, .paused].contains($0.status)) && $0.url == url && $0.quality == quality &&
                URL(fileURLWithPath: $0.directory).standardizedFileURL == URL(fileURLWithPath: directory).standardizedFileURL && $0.cookieBrowser == job.cookieBrowser
            }
            error = nil
            if duplicate == nil { jobs.insert(job, at: 0); persist() }
            // Submission is immediate. Engine checks and extraction continue in the task list.
            cancelInspection(); showingNew = false; urlInput = ""; submittedDraft = true
            selectedSection = "全部任务"; search = ""
            showNotice(duplicate == nil ? "已加入下载队列" : "此任务已在队列中，无需重复添加")
            pump()
        } catch { self.error = error.localizedDescription }
    }

    func cancelNewDownload() { invalidatePreview() }

    private func showNotice(_ message: String) {
        noticeTask?.cancel(); notice = message
        noticeTask = Task {
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            notice = nil; noticeTask = nil
        }
    }

    func pasteLink() {
        if let value = NSPasteboard.general.string(forType: .string) { urlInput = value.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "选择下载位置"
        if panel.runModal() == .OK, let url = panel.url {
            directory = url.path; preferences.set(directory, forKey: "downloadDirectory")
        }
    }

    func pause(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].status.active || jobs[index].status == .queued else { return }
        jobs[index].status = .paused; jobs[index].speed = ""; jobs[index].eta = ""; workers[id]?.cancel(); persist()
    }

    func resume(_ id: UUID) {
        guard workers[id] == nil, let job = jobs.first(where: { $0.id == id }), [.paused, .failed, .cancelled].contains(job.status) else { return }
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

    func refreshEngine() { confirmedEngine = nil; Task { _ = await prepareEngine() } }

    func shutdown() {
        quitting = true; inspection?.cancel(); preparationTask?.cancel(); queuePreparation?.cancel()
        progressSave?.cancel(); progressSave = nil; noticeTask?.cancel()
        for id in Array(workers.keys) { pause(id) }
        persist()
    }

    private func edit(_ id: UUID, _ change: (inout DownloadJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index]); persist()
    }

    private func persist() {
        progressSave?.cancel(); progressSave = nil
        do { try JobHistory.save(jobs, to: historyURL) }
        catch { self.error = "无法保存任务记录：" + error.localizedDescription }
    }

    private func pump() {
        guard !quitting, jobs.contains(where: { $0.status == .queued }) else { return }
        guard !enginePreparing, let path = paths.downloader, confirmedEngine == path else {
            guard queuePreparation == nil else { return }
            queuePreparation = Task {
                let ready = await prepareEngine()
                queuePreparation = nil
                guard !quitting else { return }
                if ready { pump() }
                else {
                    for id in jobs.filter({ $0.status == .queued }).map(\.id) {
                        edit(id) { $0.status = .failed; $0.error = engineSetupError ?? "引擎未就绪，请重试任务。" }
                    }
                }
            }
            return
        }
        while workers.count < 2, let job = jobs.first(where: { $0.status == .queued && workers[$0.id] == nil }) {
            let process = EngineProcess(), engine = DownloadEngine(paths: paths), id = job.id
            workers[id] = process; edit(id) { $0.status = .preparing }
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
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].status.active else { return }
        switch event {
        case .progress(let progress, let speed, let eta):
            guard jobs[index].status != .processing, progress.isFinite else { return }
            jobs[index].progress = max(jobs[index].progress, min(0.95, max(0, progress)))
            jobs[index].speed = speed; jobs[index].eta = eta; jobs[index].status = .downloading
            if progressSave == nil {
                progressSave = Task {
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                    persist()
                }
            }
        case .processing: edit(id) { $0.status = .processing; $0.progress = max($0.progress, 0.95); $0.speed = ""; $0.eta = "" }
        case .title(let title): edit(id) { $0.title = title; if $0.status == .preparing { $0.status = .downloading } }
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
