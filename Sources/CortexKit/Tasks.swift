import Foundation

/// One open `- [ ]` item somewhere in the vault.
public struct VaultTask: Identifiable, Sendable, Equatable {
    public let noteID: String
    public let noteTitle: String
    /// The text shown, without the checkbox and the due date.
    public let text: String
    /// The line exactly as it stands in the note, used to find it again when ticking it off.
    public let line: String
    public let due: Date?
    public let position: Int

    public var id: String { "\(noteID)#\(position)" }
}

public enum Tasks {
    public enum TaskError: LocalizedError {
        case changed
        public var errorDescription: String? { "The note changed, so this task is no longer where it was." }
    }

    private static let finishedStatuses: Set<String> = ["abgeschlossen", "done", "archiviert"]
    private static let dueDate = try! NSRegularExpression(pattern: #"(?:📅|due:)\s*(\d{4}-\d{2}-\d{2})"#)

    /// Every open task in the user's own notes. Finished projects, packs and unreviewed proposals don't count.
    /// Overdue and dated tasks come first.
    public static func open(in notes: [Note]) -> [VaultTask] {
        notes.filter { note in
            note.pack == nil && !note.isProposal && !finishedStatuses.contains(note.status?.lowercased() ?? "")
        }
        .flatMap(scan)
        .sorted { a, b in
            switch (a.due, b.due) {
            case let (x?, y?): x < y
            case (_?, nil): true
            default: false
            }
        }
    }

    static func scan(_ note: Note) -> [VaultTask] {
        var inCode = false
        var out: [VaultTask] = []
        for line in note.body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inCode.toggle(); continue }
            guard !inCode, ["- [ ] ", "* [ ] ", "+ [ ] "].contains(where: trimmed.hasPrefix) else { continue }
            let raw = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            let (text, due) = splitDue(raw)
            out.append(VaultTask(noteID: note.id, noteTitle: note.title, text: text, line: line, due: due, position: out.count))
        }
        return out
    }

    private static func splitDue(_ raw: String) -> (String, Date?) {
        let range = NSRange(raw.startIndex..., in: raw)
        guard let match = dueDate.firstMatch(in: raw, range: range),
              let whole = Range(match.range, in: raw), let day = Range(match.range(at: 1), in: raw) else { return (raw, nil) }
        return (raw.replacingCharacters(in: whole, with: "").trimmingCharacters(in: .whitespaces), Parser.date(String(raw[day])))
    }

    /// Ticks the task off in its note. The file is read fresh, so edits made elsewhere since the last scan survive.
    public static func complete(_ task: VaultTask, in note: Note) throws {
        var lines = try String(contentsOf: note.url, encoding: .utf8).components(separatedBy: "\n")
        guard let i = lines.firstIndex(of: task.line), let box = lines[i].range(of: "[ ]") else { throw TaskError.changed }
        lines[i].replaceSubrange(box, with: "[x]")
        try lines.joined(separator: "\n").write(to: note.url, atomically: true, encoding: .utf8)
    }
}
