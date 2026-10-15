import Foundation

/// One thing an AI tool (or the user) did with the memory. Appended by the MCP server, tailed by the app
/// to light up the graph live ("Recall Theater").
public struct ActivityEvent: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable { case recall, core, read, remember }

    public let time: Date
    public let client: String
    public let kind: Kind
    public let query: String?
    public let hits: [Hit]
    public let note: String?
    /// Vault path, so an app showing one vault ignores activity from another.
    public let vault: String?

    public var id: String { "\(time.timeIntervalSince1970)-\(kind.rawValue)-\(client)-\(query ?? note ?? "")" }

    public init(time: Date = Date(), client: String, kind: Kind, query: String? = nil, hits: [Hit] = [], note: String? = nil, vault: URL? = nil) {
        self.time = time
        self.client = client
        self.kind = kind
        self.query = query
        self.hits = hits
        self.note = note
        self.vault = vault?.standardizedFileURL.path
    }
}

public enum ActivityLog {
    public static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cortex/activity.jsonl")
    }

    public static func append(_ event: ActivityEvent) {
        guard var line = try? encoder.encode(event) else { return }
        line.append(0x0A)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    /// Events written after `offset` (bytes), and the new offset to continue from.
    public static func read(from offset: UInt64) -> (events: [ActivityEvent], offset: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], offset) }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        let start = offset > end ? 0 : offset // log was truncated or replaced
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        // Only consume complete lines; a half-written last line is read next time.
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return ([], start) }
        let complete = data[data.startIndex...lastNewline]
        let events = complete.split(separator: 0x0A).compactMap { try? decoder.decode(ActivityEvent.self, from: Data($0)) }
        return (events, start + UInt64(complete.count))
    }

    /// The most recent events (for the activity panel on launch).
    public static func recent(_ limit: Int = 50) -> (events: [ActivityEvent], offset: UInt64) {
        let (events, offset) = read(from: 0)
        return (Array(events.suffix(limit)), offset)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
