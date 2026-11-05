import Foundation

/// One tracker per download attempt. Format weights stay fixed when byte estimates change.
public struct DownloadProgress {
    private struct Track {
        let id: String
        let weight: Double
        var fraction: Double = 0
    }
    private var tracks: [Track] = []
    private var displayed: Double
    private var processing = false

    public init(previousProgress: Double = 0) {
        displayed = previousProgress.isFinite ? min(0.95, max(0, previousProgress)) : 0
    }

    public mutating func consume(_ line: String) -> EngineEvent? {
        if line.hasPrefix("FLOW_PLAN:") {
            if let data = String(line.dropFirst("FLOW_PLAN:".count)).data(using: .utf8),
               let formats = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !formats.isEmpty {
                let sizes = formats.compactMap { Self.positive($0["filesize"]) ?? Self.positive($0["filesize_approx"]) }
                let fallback = sizes.isEmpty ? 1 : sizes.reduce(0, +) / Double(sizes.count)
                var ids = Set<String>()
                tracks = formats.compactMap { format in
                    guard let id = format["format_id"] as? String, ids.insert(id).inserted else { return nil }
                    return Track(id: id, weight: Self.positive(format["filesize"]) ?? Self.positive(format["filesize_approx"]) ?? fallback)
                }
            }
            return nil
        }
        if line == "FLOW_PROCESSING" || line.hasPrefix("FLOW_PROCESSING:") {
            processing = true
            return .processing
        }
        guard line.hasPrefix("FLOW_PROGRESS:"),
              let data = String(line.dropFirst("FLOW_PROGRESS:".count)).data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return EngineEvent.parse(line) }
        // Accept older unwrapped hooks too, including engines used by existing integrations.
        let sample = envelope["progress"] as? [String: Any] ?? envelope
        guard !processing else { return nil }
        let id = envelope["format_id"] as? String ?? "default"
        if tracks.isEmpty { tracks = [Track(id: id, weight: 1)] }
        guard let index = tracks.firstIndex(where: { $0.id == id }) else {
            // Unknown hooks must not reset an established multi-track plan.
            return nil
        }
        let total = Self.positive(sample["total_bytes"]) ?? Self.positive(sample["total_bytes_estimate"])
        let bytes = Self.positive(sample["downloaded_bytes"]) ?? 0
        var fraction = total.map { min(1, bytes / $0) } ?? 0
        if total == nil, let count = Self.positive(sample["fragment_count"]),
           let fragment = Self.positive(sample["fragment_index"]) { fraction = min(1, fragment / count) }
        if sample["status"] as? String == "finished" { fraction = 1 }
        tracks[index].fraction = max(tracks[index].fraction, fraction)
        let overall = tracks.reduce(0) { $0 + $1.weight * $1.fraction } / tracks.reduce(0) { $0 + $1.weight }
        displayed = max(displayed, min(0.95, overall * 0.95))
        let speed = Self.positive(sample["speed"])
        let rate = speed.map { ByteCountFormatter.string(fromByteCount: Int64(min($0, Double(Int64.max / 2))), countStyle: .file) + "/s" } ?? ""
        // yt-dlp's ETA describes only the current track. Label it accordingly for multi-track jobs.
        let eta = Self.positive(sample["eta"]).map { "\(tracks.count > 1 ? "当前音视频流" : "预计剩余") \(Int(min($0, 360_000_000))) 秒" } ?? ""
        return .progress(displayed, rate, eta)
    }

    private static func positive(_ value: Any?) -> Double? {
        guard let number = (value as? NSNumber)?.doubleValue, number.isFinite, number > 0 else { return nil }
        return number
    }
}

/// EngineProcess invokes line callbacks serially; the lock also makes the boundary explicit.
final class DownloadEventStream: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: DownloadProgress
    init(previousProgress: Double) { progress = DownloadProgress(previousProgress: previousProgress) }
    func consume(_ line: String) -> EngineEvent? {
        lock.lock(); defer { lock.unlock() }
        return progress.consume(line)
    }
}
