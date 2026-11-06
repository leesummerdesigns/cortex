import Foundation

/// AI tools never write memories directly: they propose, the user reviews in Cortex.
public enum Proposals {
    /// Writes a proposal note into the vault inbox and returns its URL.
    @discardableResult
    public static func propose(title: String, content: String, tags: [String] = [], decision: Capture.Decision? = nil,
                               source: String, vault: URL) throws -> URL {
        let folder = Vault.inboxFolder(vault)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let url = uniqueURL(title: title, in: folder)

        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        var frontmatter = ["status: proposal", "source: \(source)", "created: \(day)"]
        if !tags.isEmpty { frontmatter.append("tags: [\(tags.joined(separator: ", "))]") }
        if let decision { frontmatter += Capture.decisionFrontmatter(decision) }
        let body = decision.map { Capture.decisionBody(content, $0) } ?? content.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = "---\n\(frontmatter.joined(separator: "\n"))\n---\n\n# \(title)\n\n\(body)\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Accepting turns the proposal into a normal memory (status: aktiv, keeps `source` for provenance).
    public static func accept(_ note: Note) throws {
        let text = try String(contentsOf: note.url, encoding: .utf8)
        try Parser.settingFrontmatter(text, key: "status", value: "aktiv").write(to: note.url, atomically: true, encoding: .utf8)
    }

    /// Discarding moves the file to the Trash (recoverable).
    public static func discard(_ note: Note) throws {
        try FileManager.default.trashItem(at: note.url, resultingItemURL: nil)
    }

    /// Marks a note private (hidden from AI tools) or shared again.
    public static func setPrivate(_ note: Note, _ isPrivate: Bool) throws {
        let text = try String(contentsOf: note.url, encoding: .utf8)
        try Parser.settingFrontmatter(text, key: "privacy", value: isPrivate ? "private" : nil)
            .write(to: note.url, atomically: true, encoding: .utf8)
    }

    /// A free file name for this title in `folder`.
    static func uniqueURL(title: String, in folder: URL) -> URL {
        let base = sanitized(title).isEmpty ? "Memory" : sanitized(title)
        var url = folder.appendingPathComponent("\(base).md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n).md")
            n += 1
        }
        return url
    }

    private static func sanitized(_ title: String) -> String {
        title.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|#^[]")).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(80)
            .description
    }
}
