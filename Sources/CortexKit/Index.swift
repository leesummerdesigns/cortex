import Foundation

public struct GraphLink: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case manual, auto }
    public let source: String
    public let target: String
    public let kind: Kind
    public let weight: Double
}

public struct GraphNode: Codable, Sendable {
    public let id: String
    public let title: String
    public let folder: String
    public let layer: Layer
    public let degree: Int
    /// Milliseconds since 1970, for the timeline.
    public let created: Double
    /// Pack colour (pack notes and the active persona only).
    public let color: String?
    public let pack: String?
    public let proposal: Bool
    public let isPrivate: Bool
}

public struct GraphPayload: Codable, Sendable {
    public let nodes: [GraphNode]
    public let links: [GraphLink]
}

public struct Hit: Codable, Sendable, Hashable {
    public let id: String
    public let score: Double

    public init(id: String, score: Double) {
        self.id = id
        self.score = score
    }
}

public struct Health: Sendable {
    public var duplicates: [(Note, Note, Double)] = []
    public var isolated: [Note] = []
    public var brokenLinks: [(Note, String)] = []
    public var proposals: [Note] = []
    public var stale: [Note] = []

    /// 0…100: starts at 100, loses points per issue (weighted, capped per category).
    public var score: Int {
        let penalty = min(20, duplicates.count * 5) + min(25, isolated.count) + min(20, brokenLinks.count * 2)
            + min(15, proposals.count * 3) + min(20, stale.count * 2)
        return max(0, 100 - penalty)
    }
}

/// In-memory index: resolved wikilinks, semantic auto-links, hybrid recall, bundles and health.
public final class Index {
    public let notes: [Note]
    public private(set) var manualLinks: [GraphLink] = []
    public private(set) var autoLinks: [GraphLink] = []
    /// (source note id, link target) for [[links]] that point nowhere.
    public private(set) var unresolvedLinks: [(String, String)] = []
    public var hasEmbeddings: Bool { !vectors.isEmpty }

    private let vault: URL?
    private var byId: [String: Note] = [:]
    private var vectors: [String: [Float]] = [:]
    private var centroid: [Float] = []
    private var embedder: Embedder?

    /// Similarity (after centering) a pair needs to become an auto-link.
    public var autoLinkThreshold: Float = 0.35
    public var autoLinksPerNote = 5

    public init(notes: [Note], vault: URL? = nil) {
        self.notes = notes
        self.vault = vault
        byId = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        resolveLinks()
    }

    private func resolveLinks() {
        // Obsidian resolves [[Name]] by basename; first match in path order wins on collisions.
        var byTitle: [String: String] = [:]
        for note in notes where byTitle[note.title.lowercased()] == nil { byTitle[note.title.lowercased()] = note.id }

        var seen = Set<String>()
        for note in notes {
            for target in note.links {
                guard let targetId = byTitle[target] else { unresolvedLinks.append((note.id, target)); continue }
                guard targetId != note.id else { continue }
                let key = [note.id, targetId].sorted().joined(separator: "\u{0}")
                if seen.insert(key).inserted {
                    manualLinks.append(GraphLink(source: note.id, target: targetId, kind: .manual, weight: 1))
                }
            }
        }
    }

    /// Embeds every note (cached by content hash) and derives auto-links. Returns false when embeddings are unavailable.
    @discardableResult
    public func buildEmbeddings() async -> Bool {
        guard let embedder = Embedder(), await embedder.prepare() else { return false }
        self.embedder = embedder
        let cache = vault.map { EmbeddingCache(vault: $0) }

        var raw: [String: [Float]] = [:]
        for note in notes {
            let text = note.title + "\n" + note.body
            let hash = EmbeddingCache.fnv(text)
            if let cached = cache?.vector(id: note.id, hash: hash) {
                raw[note.id] = cached
            } else if let v = embedder.embed(text) {
                raw[note.id] = v
                cache?.store(id: note.id, hash: hash, vector: v)
            }
        }
        cache?.save(keeping: Set(notes.map(\.id)))
        // Mean-pooled transformer vectors all point roughly the same way; centering makes cosine meaningful.
        centroid = Vector.mean(Array(raw.values))
        vectors = raw.mapValues { Vector.normalized(Vector.subtract($0, centroid)) }
        buildAutoLinks()
        return true
    }

    private func buildAutoLinks() {
        let manual = Set(manualLinks.map { [$0.source, $0.target].sorted().joined(separator: "\u{0}") })
        var seen = Set<String>()
        let ids = vectors.keys.sorted()
        autoLinks = []
        for a in ids {
            let va = vectors[a]!
            let best = ids.lazy.filter { $0 != a }
                .map { ($0, Vector.dot(va, self.vectors[$0]!)) }
                .sorted { $0.1 > $1.1 }
                .prefix(autoLinksPerNote)
            for (b, sim) in best where sim >= autoLinkThreshold {
                let key = [a, b].sorted().joined(separator: "\u{0}")
                guard !manual.contains(key), seen.insert(key).inserted else { continue }
                autoLinks.append(GraphLink(source: a, target: b, kind: .auto, weight: Double(sim)))
            }
        }
    }

    public func graph() -> GraphPayload {
        let links = manualLinks + autoLinks
        var degree: [String: Int] = [:]
        for l in manualLinks { degree[l.source, default: 0] += 1; degree[l.target, default: 0] += 1 }
        let nodes = notes.map {
            GraphNode(id: $0.id, title: $0.title, folder: $0.folder, layer: $0.layer, degree: degree[$0.id] ?? 0,
                      created: ($0.created.timeIntervalSince1970 * 1000).rounded(), color: $0.pack?.color,
                      pack: $0.pack?.name, proposal: $0.isProposal, isPrivate: $0.isPrivate)
        }
        return GraphPayload(nodes: nodes, links: links)
    }

    public func note(_ id: String) -> Note? { byId[id] }

    /// Finds a note by id or (case-insensitive) title.
    public func find(_ reference: String) -> Note? {
        if let n = byId[reference] { return n }
        let lower = reference.lowercased()
        return notes.first { $0.title.lowercased() == lower } ?? notes.first { $0.id.lowercased().hasSuffix(lower) }
    }

    public func neighbours(of id: String) -> (outgoing: [Note], backlinks: [Note], similar: [(Note, Double)]) {
        let out = manualLinks.filter { $0.source == id }.compactMap { byId[$0.target] }
        let back = manualLinks.filter { $0.target == id }.compactMap { byId[$0.source] }
        let similar = autoLinks.compactMap { l -> (Note, Double)? in
            if l.source == id, let n = byId[l.target] { return (n, l.weight) }
            if l.target == id, let n = byId[l.source] { return (n, l.weight) }
            return nil
        }.sorted { $0.1 > $1.1 }
        return (out, back, similar)
    }

    /// Hybrid recall: keyword relevance + semantic similarity, scores normalised to 0…1.
    /// `forAI` hides private notes and pending proposals (what AI tools may see).
    public func recall(_ query: String, limit: Int = 8, forAI: Bool = false) -> [Hit] {
        let terms = Self.tokens(query)
        guard !terms.isEmpty else { return [] }
        let candidates = forAI ? notes.filter { !$0.isPrivate && !$0.isProposal } : notes

        var semantic: [String: Double] = [:]
        if let embedder, let q = embedder.embed(query) {
            let qv = Vector.normalized(Vector.subtract(q, centroid))
            for note in candidates { if let v = vectors[note.id] { semantic[note.id] = Double(max(0, Vector.dot(qv, v))) } }
        }

        var keyword: [String: Double] = [:]
        for note in candidates {
            let title = note.title.lowercased()
            let body = note.body.lowercased()
            var s = 0.0
            for t in terms {
                if title.contains(t) { s += 3 }
                let n = body.components(separatedBy: t).count - 1
                if n > 0 { s += 1 + log(Double(n)) }
            }
            if s > 0 { keyword[note.id] = s }
        }

        let maxSem = semantic.values.max() ?? 0
        let maxKey = keyword.values.max() ?? 0
        let semWeight = maxSem > 0 ? 0.55 : 0
        let keyWeight = 1 - semWeight
        var combined: [String: Double] = [:]
        for note in candidates {
            let s = (maxSem > 0 ? (semantic[note.id] ?? 0) / maxSem : 0) * semWeight
                + (maxKey > 0 ? (keyword[note.id] ?? 0) / maxKey : 0) * keyWeight
            if s > 0.15 { combined[note.id] = s }
        }
        let top = combined.sorted { $0.value > $1.value }.prefix(limit)
        let best = top.first?.value ?? 1
        return top.map { Hit(id: $0.key, score: $0.value / best) }
    }

    // MARK: Bundles (what an AI gets to read)

    /// Core layer (identity, style, preferences + active persona) as one Markdown document, private notes excluded.
    public func coreBundle(maxCharacters: Int = 16_000) -> String {
        let core = notes.filter { $0.layer == .core && !$0.isPrivate && !$0.isProposal }
        var out = "# Core memory\n\nWho the user is and how to work with them. Always applies.\n"
        for note in core {
            let section = "\n## \(note.title)\(note.pack.map { " (persona: \($0.name))" } ?? "")\n\n\(note.body.trimmingCharacters(in: .whitespacesAndNewlines))\n"
            if out.count + section.count > maxCharacters { out += "\n(… core truncated to fit the budget)\n"; break }
            out += section
        }
        return out
    }

    /// Core + recalled memories as a paste-ready Markdown context for any AI tool, within a character budget.
    public func contextBundle(query: String, hits: [Hit], maxCharacters: Int = 24_000) -> String {
        var out = coreBundle(maxCharacters: maxCharacters / 2)
        out += "\n# Relevant memories for: \(query)\n"
        for hit in hits {
            guard let note = byId[hit.id], !note.isPrivate else { continue }
            let room = maxCharacters - out.count
            guard room > 300 else { break }
            let body = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
            out += "\n## \(note.title)\n_\(note.folder)_\n\n\(String(body.prefix(room - 200)))\n"
        }
        return out
    }

    /// Rough token estimate (~4 characters per token).
    public static func tokens(estimateFor text: String) -> Int { text.count / 4 }

    // MARK: Health

    public func health() -> Health {
        var h = Health()
        let own = notes.filter { $0.pack == nil }
        var linked = Set<String>()
        for l in manualLinks + autoLinks { linked.insert(l.source); linked.insert(l.target) }
        h.isolated = own.filter { !linked.contains($0.id) }
        h.brokenLinks = unresolvedLinks.compactMap { src, target in byId[src].map { ($0, target) } }
        h.proposals = own.filter(\.isProposal)
        let ninetyDays = Date().addingTimeInterval(-90 * 86_400)
        h.stale = own.filter { $0.layer == .context && $0.modified < ninetyDays }

        let ownIds = Set(own.map(\.id))
        h.duplicates = autoLinks
            .filter { $0.weight >= 0.92 && ownIds.contains($0.source) && ownIds.contains($0.target) }
            .compactMap { l in
                guard let a = byId[l.source], let b = byId[l.target] else { return nil }
                return (a, b, l.weight)
            }
        return h
    }

    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
    }
}
