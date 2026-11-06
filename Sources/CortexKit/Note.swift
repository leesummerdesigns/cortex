import Foundation

public enum Layer: String, Codable, CaseIterable, Sendable {
    /// Always loaded: the user's identity, style and preferences (+ the active persona).
    case core
    /// Loaded when the topic matches: active projects and areas.
    case context
    /// Loaded on search: everything else the user wrote.
    case memory
    /// Installed knowledge packs, connected to the user's own memories.
    case pack
}

public struct Note: Identifiable, Sendable {
    /// Vault-relative path without extension, e.g. "00 Kontext/Schreibstil".
    /// Pack notes are prefixed: "pack:<pack-id>/<path>".
    public let id: String
    public let title: String
    public let url: URL
    public let folder: String
    public let frontmatter: [String: FrontmatterValue]
    public let body: String
    /// Lowercased wikilink targets (basename only), attachments excluded.
    public let links: [String]
    public let layer: Layer
    public let created: Date
    public let modified: Date
    /// Set for notes that come from an installed pack.
    public let pack: PackManifest?

    public init(id: String, title: String, url: URL, folder: String, frontmatter: [String: FrontmatterValue], body: String,
                links: [String], layer: Layer, created: Date = .distantPast, modified: Date = .distantPast, pack: PackManifest? = nil) {
        self.id = id
        self.title = title
        self.url = url
        self.folder = folder
        self.frontmatter = frontmatter
        self.body = body
        self.links = links
        self.layer = layer
        self.created = created
        self.modified = modified
        self.pack = pack
    }

    public var status: String? { frontmatter["status"]?.string }
    public var tags: [String] { frontmatter["tags"]?.list ?? [] }
    /// Private notes are visible in Cortex but never handed to AI tools.
    public var isPrivate: Bool { frontmatter["privacy"]?.string?.lowercased() == "private" }
    /// Written by an AI tool and waiting for the user's review.
    public var isProposal: Bool { status?.lowercased() == "proposal" }
    public var source: String? { frontmatter["source"]?.string }
    /// A decision logged with its reasoning (`type: decision`).
    public var isDecision: Bool { frontmatter["type"]?.string?.lowercased() == "decision" }
    /// The day this note asks to be looked at again (`revisit:`).
    public var revisit: Date? { frontmatter["revisit"]?.string.flatMap(Parser.date) }
    /// The group this note clusters with on the graph (`group:`). Pack notes cluster by pack instead.
    public var group: String? {
        guard pack == nil, let group = frontmatter["group"]?.string?.trimmingCharacters(in: .whitespaces), !group.isEmpty
        else { return nil }
        return group
    }
}

public enum FrontmatterValue: Sendable, Equatable {
    case string(String)
    case list([String])

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var list: [String]? {
        switch self {
        case .list(let l): return l
        case .string(let s): return s.isEmpty ? [] : [s]
        }
    }
}
