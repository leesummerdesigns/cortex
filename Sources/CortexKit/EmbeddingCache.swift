import Foundation

/// Raw (uncentered) note vectors keyed by note id + content hash, so only changed notes are re-embedded.
/// Lives in ~/Library/Caches/Cortex/<vault-hash>/ — never inside the vault.
final class EmbeddingCache {
    private struct Entry: Codable {
        let hash: UInt64
        let vector: Data
    }

    private static let version = "nl-latin-v1"
    private let url: URL
    private var entries: [String: Entry] = [:]
    private var dirty = false

    init(vault: URL) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        url = caches.appendingPathComponent("Cortex/\(String(Self.fnv(vault.standardizedFileURL.path), radix: 16))/embeddings-\(Self.version).json")
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        }
    }

    func vector(id: String, hash: UInt64) -> [Float]? {
        guard let e = entries[id], e.hash == hash else { return nil }
        return e.vector.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    func store(id: String, hash: UInt64, vector: [Float]) {
        entries[id] = Entry(hash: hash, vector: vector.withUnsafeBufferPointer { Data(buffer: $0) })
        dirty = true
    }

    /// Drops entries for notes that no longer exist, then writes if anything changed.
    func save(keeping ids: Set<String>) {
        let before = entries.count
        entries = entries.filter { ids.contains($0.key) }
        guard dirty || entries.count != before else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: url, options: .atomic) }
    }

    static func fnv(_ text: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in text.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
}
