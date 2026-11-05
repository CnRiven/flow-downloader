import Foundation
import FlowCore

enum ProgressChecks {
    private static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw InputError.processFailed(message) }
    }
    private static func sample(_ id: String, _ bytes: Int, _ total: Int?, finished: Bool = false) -> String {
        let progress: [String: Any] = ["status": finished ? "finished" : "downloading", "downloaded_bytes": bytes,
                                       "total_bytes_estimate": total as Any? ?? NSNull(), "speed": 1024, "eta": 3]
        let data = try! JSONSerialization.data(withJSONObject: ["format_id": id, "progress": progress])
        return "FLOW_PROGRESS:" + String(decoding: data, as: UTF8.self)
    }
    private static func fraction(_ event: EngineEvent?) throws -> Double {
        guard case .progress(let value, _, _) = event else { throw InputError.processFailed("Expected download progress") }
        return value
    }
    static func run() throws {
        var tracker = DownloadProgress()
        _ = tracker.consume("FLOW_PLAN:[{\"format_id\":\"video\",\"filesize\":900},{\"format_id\":\"audio\",\"filesize\":100}]")
        var values: [Double] = []
        for line in [sample("video", 450, 900), sample("video", 450, 1800), sample("video", 900, 900, finished: true),
                     sample("audio", 1, 100), sample("audio", 100, 100, finished: true)] {
            values.append(try fraction(tracker.consume(line)))
        }
        try expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }, "Track switch or revised size decreased overall progress")
        try expect(abs(values[2] - 0.855) < 0.0001 && values[3] > values[2], "Tracks were not weighted by their sizes")
        try expect(values.last == 0.95, "Transfer must reserve completion for postprocessing")
        try expect(tracker.consume("FLOW_PROCESSING") == .processing, "Missing explicit postprocessing phase")
        try expect(tracker.consume(sample("audio", 1, 100)) == nil, "Delayed transfer hook reset processing state")

        var estimated = DownloadProgress()
        _ = estimated.consume("FLOW_PLAN:[{\"format_id\":\"v\"},{\"format_id\":\"a\"}]")
        let first = try fraction(estimated.consume(sample("v", 1, nil, finished: true)))
        try expect(abs(first - 0.475) < 0.0001, "Unknown track sizes need a balanced fallback")
        try expect(try fraction(estimated.consume(sample("a", 0, nil))) == first, "Unknown lengths reset progress")
        try expect(try fraction(estimated.consume(sample("a", 2, nil, finished: true))) == 0.95, "Unknown lengths never completed")
        var resumed = DownloadProgress(previousProgress: 0.7)
        try expect(try fraction(resumed.consume(sample("video", 1, 100))) == 0.7, "Resuming decreased persisted progress")
        var fragments = DownloadProgress()
        let fragmented = "FLOW_PROGRESS:{\"format_id\":\"v\",\"progress\":{\"fragment_index\":3,\"fragment_count\":10,\"speed\":-1}}"
        try expect(abs(try fraction(fragments.consume(fragmented)) - 0.285) < 0.0001, "Fragment counts not supported")
        print("PASS overall multi-track progress, changing estimates, unknown lengths, fragments, resume and processing phases")
    }
}
