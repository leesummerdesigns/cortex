import Foundation

/// Getting a thought into the vault with as few decisions as possible.
public enum Capture {
    /// A decision keeps its reasoning and, optionally, the day it should come back for a second look.
    public struct Decision: Sendable, Equatable {
        public var why: String
        public var alternatives: String
        public var revisit: Date?

        public init(why: String = "", alternatives: String = "", revisit: Date? = nil) {
            self.why = why
            self.alternatives = alternatives
            self.revisit = revisit
        }
    }

    /// Saves `text` as a normal note. The first line becomes the title, the rest the body.
    /// Goes to the inbox unless a folder (vault-relative) is given.
    @discardableResult
    public static func save(_ text: String, decision: Decision? = nil, folder: String? = nil, source: String = "quick capture",
                            vault: URL, now: Date = Date()) throws -> URL {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        let first = (lines.first ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
        let plain = first.replacingOccurrences(of: #"\[\[(?:[^\]\|]+\|)?([^\]]+)\]\]"#, with: "$1", options: .regularExpression)
        let title = plain.isEmpty ? "Note" : shortened(plain)
        let rest = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        let target = folder.map { vault.appendingPathComponent($0) } ?? Vault.inboxFolder(vault)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let url = Proposals.uniqueURL(title: title, in: target)

        var frontmatter = ["created: \(day(now))", "source: \(source)"]
        if let decision { frontmatter += decisionFrontmatter(decision) }
        // A first line the title can't hold (too long, or with links in it) stays in the body so nothing is lost.
        let full = first != title ? first + (rest.isEmpty ? "" : "\n\n" + rest) : rest
        let content = decision.map { decisionBody(full, $0) } ?? full
        let body = content.isEmpty ? "# \(title)\n" : "# \(title)\n\n\(content)\n"
        try "---\n\(frontmatter.joined(separator: "\n"))\n---\n\n\(body)".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Cuts at a word boundary so a title never ends mid-word.
    private static func shortened(_ text: String, limit: Int = 70) -> String {
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        return cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
    }

    static func decisionFrontmatter(_ decision: Decision) -> [String] {
        ["type: decision"] + (decision.revisit.map { ["revisit: \(day($0))"] } ?? [])
    }

    static func decisionBody(_ decided: String, _ decision: Decision) -> String {
        var parts = [decided.trimmingCharacters(in: .whitespacesAndNewlines)]
        let why = decision.why.trimmingCharacters(in: .whitespacesAndNewlines)
        let alternatives = decision.alternatives.trimmingCharacters(in: .whitespacesAndNewlines)
        if !why.isEmpty { parts.append("## Why\n\n\(why)") }
        if !alternatives.isEmpty { parts.append("## Alternatives considered\n\n\(alternatives)") }
        parts.append("## Outcome\n\n_Fill this in when you revisit the decision._")
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// `yyyy-MM-dd` in the user's time zone.
    public static func day(_ date: Date) -> String {
        ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withFullDate])
    }
}

public extension Index {
    /// Where similar notes already live, so filing a new one takes a click instead of a decision.
    /// Ignores the inbox, the core, packs and dated notes, which say nothing about the topic.
    func suggestFolder(for text: String) -> String? {
        let folders = recall(text, limit: 6).compactMap { note($0.id) }
            .filter { note in
                note.pack == nil && note.layer != .core && !note.folder.isEmpty
                    && !note.folder.hasPrefix("01") && !note.folder.hasPrefix("Inbox")
                    && Parser.createdDate(title: note.title, frontmatter: [:]) == nil
            }
            .prefix(3)
            .map(\.folder)
        return folders.max { a, b in folders.filter { $0 == a }.count < folders.filter { $0 == b }.count }
    }
}
