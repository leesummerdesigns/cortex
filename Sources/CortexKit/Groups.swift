import Foundation

/// Groups gather related notes into one coloured cluster on the graph.
/// Membership is the note's `group:` frontmatter (one group per note); colours live in the vault config.
public enum Groups {
    /// Distinct from the layer colours and readable on dark and light backgrounds.
    public static let palette = ["#4fb3bf", "#e0a458", "#9b7ede", "#6cc070", "#e07a9f", "#5b8def", "#d4c45a", "#ef7d57"]

    /// The saved colour, else a palette colour derived from the name (stable for groups typed in another editor).
    public static func color(_ group: String, config: CortexConfig) -> String {
        config.groupColors[group] ?? palette[Int(EmbeddingCache.fnv(group) % UInt64(palette.count))]
    }

    /// First palette colour none of the existing groups uses, for a newly created group.
    public static func nextColor(existing: [String], config: CortexConfig) -> String {
        let used = Set(existing.map { color($0, config: config) })
        return palette.first { !used.contains($0) } ?? palette[existing.count % palette.count]
    }

    /// Moves the note into `group`, or out of its group when nil.
    public static func assign(_ note: Note, to group: String?) throws {
        let text = try String(contentsOf: note.url, encoding: .utf8)
        try Parser.settingFrontmatter(text, key: "group", value: group.map(yamlScalar))
            .write(to: note.url, atomically: true, encoding: .utf8)
    }

    /// Quotes names YAML would misread (colons, #, brackets, leading dash).
    static func yamlScalar(_ name: String) -> String {
        let special = CharacterSet(charactersIn: ":#{}[],&*!|>'\"%@`")
        guard name.rangeOfCharacter(from: special) != nil || name.hasPrefix("-") || name.hasPrefix("?") else { return name }
        return "\"\(name.replacingOccurrences(of: "\"", with: "'"))\""
    }
}
