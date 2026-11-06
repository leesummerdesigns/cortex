import Foundation

/// Which memories AI tools actually use. A graph shows that connections exist; this shows which notes matter.
public struct UsageReport: Sendable {
    public var used: [(note: Note, count: Int)] = []
    /// Notes older than a month that no AI has touched in the window.
    public var unused: [Note] = []
    public var eligible = 0
    /// When the log starts, because a young log can't yet say much.
    public var since: Date?

    public var usedPercent: Int { eligible == 0 ? 0 : Int((Double(used.count) / Double(eligible) * 100).rounded()) }
}

public enum Usage {
    public static func report(events: [ActivityEvent], notes: [Note], vault: URL?, now: Date = Date(), days: Double = 90) -> UsageReport {
        let path = vault?.standardizedFileURL.path
        let start = now.addingTimeInterval(-days * 86_400)
        let relevant = events.filter { ($0.vault == nil || $0.vault == path) && $0.time >= start }

        var counts: [String: Int] = [:]
        // The core is loaded every time, so counting it would say nothing.
        for event in relevant where event.kind == .recall || event.kind == .read {
            for hit in event.hits { counts[hit.id, default: 0] += 1 }
        }

        let eligible = notes.filter { $0.pack == nil && $0.layer != .core && !$0.isProposal && !$0.isPrivate }
        var report = UsageReport()
        report.eligible = eligible.count
        report.since = relevant.map(\.time).min()
        report.used = eligible.compactMap { note in counts[note.id].map { (note, $0) } }.sorted { $0.count > $1.count }
        let monthAgo = now.addingTimeInterval(-30 * 86_400)
        report.unused = eligible.filter { counts[$0.id] == nil && $0.created < monthAgo }.sorted { $0.created < $1.created }
        return report
    }
}
