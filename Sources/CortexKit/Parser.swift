import Foundation

public enum Parser {
    /// Splits a Markdown file into YAML frontmatter (flat keys, scalars and lists only) and body.
    public static func frontmatter(_ text: String) -> ([String: FrontmatterValue], String) {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return ([:], text) }

        var result: [String: FrontmatterValue] = [:]
        var currentKey: String?
        for line in lines[1..<end] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- "), let key = currentKey {
                let item = unquote(String(trimmed.dropFirst(2)))
                result[key] = .list((result[key]?.list ?? []) + [item])
                continue
            }
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            currentKey = key
            if value.hasPrefix("[") && value.hasSuffix("]") {
                let items = value.dropFirst().dropLast().split(separator: ",")
                    .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
                    .filter { !$0.isEmpty }
                result[key] = .list(items)
            } else {
                result[key] = .string(unquote(value))
            }
        }
        let body = lines[(end + 1)...].joined(separator: "\n")
        return (result, body)
    }

    private static let wikilink = try! NSRegularExpression(pattern: #"\[\[([^\]\|#]+)(?:#[^\]\|]*)?(?:\|[^\]]*)?\]\]"#)
    private static let attachmentExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "pdf", "mp3", "ogg", "mp4", "base", "canvas"]

    /// Lowercased basenames of [[wikilinks]], without headings/aliases and without attachments.
    public static func wikilinks(_ text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        var out: [String] = []
        for match in wikilink.matches(in: text, range: range) {
            guard let r = Range(match.range(at: 1), in: text) else { continue }
            var target = text[r].trimmingCharacters(in: .whitespaces)
            if let slash = target.lastIndex(of: "/") { target = String(target[target.index(after: slash)...]) }
            let ext = (target as NSString).pathExtension.lowercased()
            if attachmentExtensions.contains(ext) { continue }
            if ext == "md" { target = (target as NSString).deletingPathExtension }
            let key = target.lowercased()
            if !key.isEmpty, seen.insert(key).inserted { out.append(key) }
        }
        return out
    }

    /// Explicit `layer:` wins; otherwise inferred from the PARA folder.
    public static func layer(relativePath: String, frontmatter: [String: FrontmatterValue]) -> Layer {
        if let raw = frontmatter["layer"]?.string, let layer = Layer(rawValue: raw.lowercased()), layer != .pack { return layer }
        let top = relativePath.split(separator: "/").first.map(String.init) ?? ""
        if top.hasPrefix("00") { return .core }
        if top.hasPrefix("02") || top.hasPrefix("03") {
            let status = frontmatter["status"]?.string?.lowercased() ?? ""
            return ["abgeschlossen", "done", "archiviert"].contains(status) ? .memory : .context
        }
        return .memory
    }

    // MARK: Dates

    private static let dateFormats = ["yyyy-MM-dd", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd HH:mm", "dd.MM.yy", "dd.MM.yyyy"]

    /// Parses the date styles found in vaults: ISO, `2026-07-06`, `01.07.26`, `01.07.2026`.
    public static func date(_ text: String) -> Date? {
        let text = text.trimmingCharacters(in: .whitespaces)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for format in dateFormats {
            f.dateFormat = format
            // DateFormatter is lenient ("01.07.26" parses as year 1 with yyyy-MM-dd), so dates must round-trip.
            if let d = f.date(from: text), format.contains("'T'") || f.string(from: d) == text { return d }
        }
        return nil
    }

    private static let titleDate = try! NSRegularExpression(pattern: #"(\d{4}-\d{2}-\d{2}|\d{2}\.\d{2}\.\d{2,4})"#)

    /// Creation date: frontmatter (`created`/`date`/`erstellt`), then a date in the title (daily notes), else nil.
    public static func createdDate(title: String, frontmatter: [String: FrontmatterValue]) -> Date? {
        for key in ["created", "date", "erstellt"] {
            if let raw = frontmatter[key]?.string, let d = date(raw) { return d }
        }
        let range = NSRange(title.startIndex..., in: title)
        if let m = titleDate.firstMatch(in: title, range: range), let r = Range(m.range, in: title) {
            return date(String(title[r]))
        }
        return nil
    }

    // MARK: Writing

    /// Sets (or removes, when `value` is nil) a top-level frontmatter key, creating a frontmatter block if needed.
    public static func settingFrontmatter(_ text: String, key: String, value: String?) -> String {
        var lines = text.components(separatedBy: "\n")
        let hasBlock = lines.first?.trimmingCharacters(in: .whitespaces) == "---"
        let end = hasBlock ? lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) : nil

        guard let end else {
            guard let value else { return text }
            return "---\n\(key): \(value)\n---\n" + text
        }
        if let i = (1..<end).first(where: { lines[$0].hasPrefix("\(key):") }) {
            // Drop the key line and any list items that belong to it.
            var j = i + 1
            while j < end, lines[j].trimmingCharacters(in: .whitespaces).hasPrefix("- ") { j += 1 }
            lines.removeSubrange(i..<j)
            if let value { lines.insert("\(key): \(value)", at: i) }
        } else if let value {
            lines.insert("\(key): \(value)", at: end)
        }
        return lines.joined(separator: "\n")
    }

    private static func unquote(_ s: String) -> String {
        var s = s
        if s.count >= 2, let f = s.first, let l = s.last, (f == "\"" && l == "\"") || (f == "'" && l == "'") {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }
}
