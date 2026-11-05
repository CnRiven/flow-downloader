import Foundation

public enum Quality: String, Codable, CaseIterable, Identifiable {
    case best, hd1080, hd720, audio
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .best: return "最佳画质"
        case .hd1080: return "1080p"
        case .hd720: return "720p"
        case .audio: return "仅音频 · MP3"
        }
    }
    public var format: String {
        switch self {
        case .best: return "bv*+ba/b"
        case .hd1080: return "bv*[height<=1080]+ba/b[height<=1080]"
        case .hd720: return "bv*[height<=720]+ba/b[height<=720]"
        case .audio: return "bestaudio/best"
        }
    }
    public var singleFileFormat: String {
        switch self {
        case .best: return "b"
        case .hd1080: return "b[height<=?1080]"
        case .hd720: return "b[height<=?720]"
        case .audio: return "bestaudio/best"
        }
    }
}

public struct VideoInfo: Codable, Equatable {
    public let title: String
    public let uploader: String?
    public let duration: Double?
    public let thumbnail: String?
    public let extractor: String?
    public var durationLabel: String {
        guard let duration, duration.isFinite, duration >= 0 else { return "时长未知" }
        let seconds = Int(min(duration, 360_000_000))
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

public enum JobStatus: String, Codable {
    case queued, downloading, processing, paused, completed, failed, cancelled
    public var label: String {
        switch self {
        case .queued: return "等待下载"
        case .downloading: return "正在下载"
        case .processing: return "正在合并 / 转换"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        case .failed: return "下载失败"
        case .cancelled: return "已取消"
        }
    }
    public var active: Bool { self == .downloading || self == .processing }
}

public struct DownloadJob: Codable, Identifiable {
    public var id: UUID
    public var url: String
    public var title: String
    public var thumbnail: String?
    public var quality: Quality
    public var directory: String
    public var cookieBrowser: String?
    public var status: JobStatus
    public var progress: Double
    public var speed: String
    public var eta: String
    public var filePath: String?
    public var error: String?
    public var createdAt: Date

    public init(url: String, info: VideoInfo?, quality: Quality, directory: String, cookieBrowser: String? = nil) {
        id = UUID(); self.url = url; title = info?.title ?? URL(string: url)?.host ?? url
        thumbnail = info?.thumbnail; self.quality = quality; self.directory = directory
        self.cookieBrowser = cookieBrowser; status = .queued; progress = 0; speed = ""; eta = ""
        createdAt = Date()
    }
}

public enum InputError: LocalizedError {
    case invalidURL, missingEngine, processFailed(String), missingOutput
    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "请粘贴完整的 http:// 或 https:// 视频链接。"
        case .missingEngine: return "下载引擎尚未就绪，请在应用内重试安装。"
        case .processFailed(let message): return message
        case .missingOutput: return "下载引擎已退出，但没有找到输出文件。请查看任务日志。"
        }
    }
}

public enum Input {
    public static func validatedURL(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, !value.contains(where: { $0.isNewline || $0.isWhitespace }) else {
            throw InputError.invalidURL
        }
        return value
    }
}

public enum JobHistory {
    public static func load(from url: URL) throws -> [DownloadJob] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([DownloadJob].self, from: Data(contentsOf: url)).map { job in
            var recovered = job
            if recovered.status.active || recovered.status == .queued { recovered.status = .paused }
            return recovered
        }
    }
    public static func save(_ jobs: [DownloadJob], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(jobs).write(to: url, options: .atomic)
    }
}
