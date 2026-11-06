import Foundation

public enum Vault {
    public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/Cortex")

    private static let keys: [URLResourceKey] = [.isDirectoryKey, .creationDateKey, .contentModificationDateKey]

    /// The user's own notes plus the notes of the active persona and enabled knowledge packs.
    public static func load(_ root: URL) throws -> [Note] {
        let root = root.standardizedFileURL
        let config = CortexConfig.load(vault: root)
        var notes = scan(root) { relative, frontmatter in Parser.layer(relativePath: relative, frontmatter: frontmatter) }

        for pack in Packs.installed(vault: root) {
            let m = pack.manifest
            let layer: Layer
            switch m.kind {
            case .persona where config.activePersona == m.id: layer = .core // the persona joins the core
            case .knowledge where config.enabledPacks.contains(m.id): layer = .pack
            default: continue
            }
            notes += scan(pack.url, idPrefix: "pack:\(m.id)/", pack: m) { _, _ in layer }
        }
        return notes.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private static func scan(_ root: URL, idPrefix: String = "", pack: PackManifest? = nil,
                             layer: (String, [String: FrontmatterValue]) -> Layer) -> [Note] {
        let root = root.standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants, .skipsHiddenFiles]
        ) else { return [] }

        var notes: [Note] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let values = try? url.resourceValues(forKeys: Set(keys))
            let relative = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            let title = url.deletingPathExtension().lastPathComponent
            let (frontmatter, body) = Parser.frontmatter(text)
            let modified = values?.contentModificationDate ?? .distantPast
            let created = Parser.createdDate(title: title, frontmatter: frontmatter) ?? values?.creationDate ?? modified
            let folder = (relative as NSString).deletingLastPathComponent
            notes.append(Note(
                id: idPrefix + (relative as NSString).deletingPathExtension,
                title: title,
                url: url,
                folder: pack.map { folder.isEmpty ? $0.name : "\($0.name)/\(folder)" } ?? folder,
                frontmatter: frontmatter,
                body: body,
                links: Parser.wikilinks(body),
                layer: layer(relative, frontmatter),
                created: created,
                modified: modified,
                pack: pack
            ))
        }
        return notes
    }

    /// Cheap fingerprint of everything that affects the index (notes, packs, config). Changes when any file changes.
    public static func signature(_ root: URL) -> String {
        var count = 0
        var latest = 0.0
        func visit(_ dir: URL, options: FileManager.DirectoryEnumerationOptions) {
            guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: options) else { return }
            // Ticking a note off in Today changes nothing the index reads, so it must not redraw the graph.
            for case let url as URL in e where ["md", "json"].contains(url.pathExtension) && url.lastPathComponent != ReviewState.fileName {
                count += 1
                let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
                latest = max(latest, m)
            }
        }
        visit(root, options: [.skipsPackageDescendants, .skipsHiddenFiles])
        visit(root.appendingPathComponent(".cortex"), options: [.skipsPackageDescendants])
        return "\(count)-\(latest)"
    }

    /// iCloud Drive keeps not-yet-downloaded notes as hidden `.Name.md.icloud` placeholders.
    /// Asks iCloud to download them and returns how many are still pending (they appear via live sync).
    @discardableResult
    public static func requestDownloads(_ root: URL) -> Int {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsPackageDescendants]) else { return 0 }
        var pending = 0
        for case let url as URL in e where url.pathExtension == "icloud" && url.lastPathComponent.hasPrefix(".") {
            let name = String(url.deletingPathExtension().lastPathComponent.dropFirst())
            guard name.hasSuffix(".md") else { continue }
            try? FileManager.default.startDownloadingUbiquitousItem(at: url.deletingLastPathComponent().appendingPathComponent(name))
            pending += 1
        }
        return pending
    }

    /// True when the folder lives in iCloud Drive (so other Macs can share the same memory).
    public static func isInICloud(_ root: URL) -> Bool {
        root.standardizedFileURL.path.contains("/Library/Mobile Documents/")
    }

    /// First launch without a vault: a few notes that show how layers and links work.
    public static func createStarter(at root: URL) throws {
        let notes = [
            "Welcome to Cortex.md": """
            # Welcome to Cortex

            Every Markdown file in this folder is a memory, and every sphere in the graph is one of them.
            Lines are [[links]] you write yourself, plus connections Cortex finds by meaning.

            - Notes in **00 Core** are what your AI always knows about you: start with [[About me]] and [[How to respond]].
            - Memories your AI suggests land in **01 Inbox** for you to review.
            - Everything else is long-term memory, recalled when it is relevant.

            Open **Connect** in the sidebar to use this memory inside Claude, Cursor and other AI apps.
            """,
            "00 Core/About me.md": """
            # About me

            Who you are, what you work on, and what you care about. Replace this with a few honest lines:
            your role, your current projects, the languages you write in.

            See also [[How to respond]].
            """,
            "00 Core/How to respond.md": """
            # How to respond

            How your AI should talk to you. For example:

            - Be direct; skip the preamble.
            - Answer in the language I write in.
            - When unsure, say so instead of guessing.

            This note is part of the core, so every connected AI reads it first. Back to [[Welcome to Cortex]].
            """,
            "01 Inbox/.keep": "",
        ]
        for (path, text) in notes {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Where AI-proposed memories are written: the PARA inbox if present.
    public static func inboxFolder(_ root: URL) -> URL {
        let candidates = ["01 Inbox", "Inbox"].map { root.appendingPathComponent($0) }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[0]
    }
}
