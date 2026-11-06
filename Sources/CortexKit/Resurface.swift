import Foundation

/// When a note may come back in Today. Kept outside the notes so a look at an old note doesn't change the file.
public struct ReviewState: Codable, Sendable, Equatable {
    public var hiddenUntil: [String: Date] = [:]

    public init() {}

    static let fileName = "review.json"
    static func url(vault: URL) -> URL { vault.appendingPathComponent(".cortex/\(fileName)") }

    public static func load(vault: URL) -> ReviewState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url(vault: vault))).flatMap { try? decoder.decode(ReviewState.self, from: $0) } ?? ReviewState()
    }

    public func save(vault: URL) throws {
        let target = Self.url(vault: vault)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: target, options: [.atomic])
    }
}

public struct ResurfaceItem: Identifiable, Sendable {
    public enum Reason: Sendable, Equatable {
        case revisitDue(Date)
        case anniversary(months: Int)
        case related(to: String)
        case oldest
    }

    public let note: Note
    public let reason: Reason
    public var id: String { note.id }
}

/// A short daily list of notes that come back on their own, because most notes are never reopened after they're written.
public enum Resurface {
    private static let forgottenAfter: TimeInterval = 60 * 86_400
    private static let activeWithin: TimeInterval = 14 * 86_400

    public static func today(index: Index, state: ReviewState, now: Date = Date(), limit: Int = 5) -> [ResurfaceItem] {
        let own = index.notes.filter { $0.pack == nil && !$0.isProposal }
        let calendar = Calendar.current
        let endOfToday = calendar.startOfDay(for: now).addingTimeInterval(86_400)
        let visible = own.filter { (state.hiddenUntil[$0.id] ?? .distantPast) <= now }

        // What the user asked to see again comes first and ignores the rest of the rules.
        var items = own.compactMap { note -> ResurfaceItem? in
            guard let revisit = note.revisit, revisit < endOfToday else { return nil }
            return ResurfaceItem(note: note, reason: .revisitDue(revisit))
        }.sorted { ($0.note.revisit ?? now) < ($1.note.revisit ?? now) }

        func add(_ candidates: [ResurfaceItem], max: Int) {
            let taken = Set(items.map(\.id))
            items += candidates.filter { !taken.contains($0.id) }.prefix(max)
        }

        add(visible.filter { $0.layer != .core }.compactMap { note in
            anniversary(of: note.created, now: now, calendar: calendar).map { ResurfaceItem(note: note, reason: .anniversary(months: $0)) }
        }.sorted { $0.note.created < $1.note.created }, max: 1)

        // Old notes close to what the user is working on now: the moment an old thought is useful again.
        let threshold = now.addingTimeInterval(-forgottenAfter)
        let forgotten = visible.filter { note in
            note.layer != .core && note.modified < threshold && Parser.createdDate(title: note.title, frontmatter: [:]) == nil
        }
        let active = own.filter { $0.layer != .core && $0.modified > now.addingTimeInterval(-activeWithin) }
        let related = forgotten.compactMap { note -> (Note, String, Double)? in
            let best = active.compactMap { other in index.closeness(note.id, other.id).map { (other.title, $0) } }.max { $0.1 < $1.1 }
            guard let best, best.1 >= Double(index.autoLinkThreshold) else { return nil }
            return (note, best.0, best.1)
        }.sorted { $0.2 > $1.2 }
        add(related.map { ResurfaceItem(note: $0.0, reason: .related(to: $0.1)) }, max: 3)

        // A vault with no recent work still gets something back: the notes untouched the longest.
        if items.isEmpty {
            add(forgotten.sorted { $0.modified < $1.modified }.map { ResurfaceItem(note: $0, reason: .oldest) }, max: 2)
        }
        return Array(items.prefix(limit))
    }

    /// Whole months since `created` when today is a round date (1, 3 or 6 months, or full years).
    static func anniversary(of created: Date, now: Date, calendar: Calendar) -> Int? {
        guard created > .distantPast else { return nil }
        let parts = calendar.dateComponents([.month, .day], from: calendar.startOfDay(for: created), to: calendar.startOfDay(for: now))
        guard parts.day == 0, let months = parts.month, months > 0,
              [1, 3, 6].contains(months) || months % 12 == 0 else { return nil }
        return months
    }
}
