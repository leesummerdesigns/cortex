import Foundation

/// `pack.json` — a pack is a folder of Markdown notes plus this manifest.
/// Persona packs change how the AI behaves (they join the core while active);
/// knowledge packs add expertise that connects to the user's own memories.
public struct PackManifest: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable { case persona, knowledge }

    public var id: String
    public var name: String
    public var author: String
    public var version: String
    public var description: String
    public var kind: Kind
    public var color: String

    public init(id: String, name: String, author: String, version: String = "1.0", description: String, kind: Kind, color: String) {
        self.id = id
        self.name = name
        self.author = author
        self.version = version
        self.description = description
        self.kind = kind
        self.color = color
    }
}

public struct InstalledPack: Identifiable, Sendable {
    public let manifest: PackManifest
    public let url: URL
    public var id: String { manifest.id }

    public init(manifest: PackManifest, url: URL) {
        self.manifest = manifest
        self.url = url
    }
    public var noteCount: Int {
        (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "md" }.count ?? 0
    }
}

/// Per-vault state, stored in `<vault>/.cortex/config.json` so the app and the MCP server agree.
public struct CortexConfig: Codable, Sendable, Equatable {
    public var activePersona: String?
    public var enabledPacks: [String] = []
    /// Group name → hex colour on the graph.
    public var groupColors: [String: String] = [:]

    public init(activePersona: String? = nil, enabledPacks: [String] = []) {
        self.activePersona = activePersona
        self.enabledPacks = enabledPacks
    }

    // Keys added in later versions may be missing from older config files.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activePersona = try c.decodeIfPresent(String.self, forKey: .activePersona)
        enabledPacks = try c.decodeIfPresent([String].self, forKey: .enabledPacks) ?? []
        groupColors = try c.decodeIfPresent([String: String].self, forKey: .groupColors) ?? [:]
    }

    public static func url(vault: URL) -> URL { vault.appendingPathComponent(".cortex/config.json") }

    public static func load(vault: URL) -> CortexConfig {
        guard let data = try? Data(contentsOf: url(vault: vault)),
              let config = try? JSONDecoder().decode(CortexConfig.self, from: data) else { return CortexConfig() }
        return config
    }

    public func save(vault: URL) throws {
        let url = Self.url(vault: vault)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

public enum PackError: LocalizedError {
    case noManifest
    case unzipFailed

    public var errorDescription: String? {
        switch self {
        case .noManifest: "This folder or archive has no pack.json."
        case .unzipFailed: "The archive could not be opened."
        }
    }
}

public enum Packs {
    public static func directory(vault: URL) -> URL { vault.appendingPathComponent(".cortex/packs") }

    public static func installed(vault: URL) -> [InstalledPack] {
        let dir = directory(vault: vault)
        let folders = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            manifest(in: folder).map { InstalledPack(manifest: $0, url: folder) }
        }.sorted { $0.manifest.name < $1.manifest.name }
    }

    public static func manifest(in folder: URL) -> PackManifest? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("pack.json")) else { return nil }
        return try? JSONDecoder().decode(PackManifest.self, from: data)
    }

    /// The Markdown notes of a pack (title, body), whether or not it is active.
    public static func notes(of pack: InstalledPack) -> [(title: String, body: String)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: pack.url, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                let (_, body) = Parser.frontmatter((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                return (url.deletingPathExtension().lastPathComponent, body.trimmingCharacters(in: .whitespacesAndNewlines))
            }
    }

    /// Finds an installed persona by id or name ("socratic-coach", "Socratic Coach", "coach").
    public static func persona(_ reference: String, vault: URL) -> InstalledPack? {
        let r = reference.lowercased().trimmingCharacters(in: .whitespaces)
        let personas = installed(vault: vault).filter { $0.manifest.kind == .persona }
        return personas.first { $0.id == r || $0.manifest.name.lowercased() == r }
            ?? personas.first { $0.id.contains(r) || $0.manifest.name.lowercased().contains(r) }
    }

    /// Installs a pack folder or `.zip` archive into the vault (replacing an older version of the same pack).
    @discardableResult
    public static func install(from source: URL, vault: URL) throws -> PackManifest {
        let fm = FileManager.default
        var folder = source
        var temp: URL?
        if source.pathExtension.lowercased() == "zip" {
            let dir = fm.temporaryDirectory.appendingPathComponent("cortex-pack-\(UUID().uuidString)")
            try run("/usr/bin/ditto", ["-x", "-k", source.path, dir.path])
            temp = dir
            folder = dir
        }
        defer { if let temp { try? fm.removeItem(at: temp) } }

        // Accept the manifest at the root or one level down (zip of the folder itself).
        if manifest(in: folder) == nil,
           let child = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?.first(where: { manifest(in: $0) != nil }) {
            folder = child
        }
        guard let manifest = manifest(in: folder) else { throw PackError.noManifest }

        let target = directory(vault: vault).appendingPathComponent(manifest.id)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.copyItem(at: folder, to: target)
        return manifest
    }

    /// Moves an installed pack to the Trash and removes it from the config.
    public static func remove(_ id: String, vault: URL) throws {
        try FileManager.default.trashItem(at: directory(vault: vault).appendingPathComponent(id), resultingItemURL: nil)
        var config = CortexConfig.load(vault: vault)
        config.enabledPacks.removeAll { $0 == id }
        if config.activePersona == id { config.activePersona = nil }
        try config.save(vault: vault)
    }

    /// Writes notes + manifest as a shareable pack. A destination ending in `.zip` is archived.
    public static func export(_ notes: [Note], manifest: PackManifest, to destination: URL) throws {
        let fm = FileManager.default
        let zip = destination.pathExtension.lowercased() == "zip"
        let folder = zip ? fm.temporaryDirectory.appendingPathComponent(manifest.id) : destination
        if fm.fileExists(atPath: folder.path) { try fm.removeItem(at: folder) }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("pack.json"))
        for note in notes {
            let text = (try? String(contentsOf: note.url, encoding: .utf8)) ?? note.body
            try text.write(to: folder.appendingPathComponent(note.url.lastPathComponent), atomically: true, encoding: .utf8)
        }
        if zip {
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", folder.path, destination.path])
            try? fm.removeItem(at: folder)
        }
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw PackError.unzipFailed }
    }
}
