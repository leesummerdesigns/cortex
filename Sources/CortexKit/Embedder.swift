import Foundation
import NaturalLanguage

/// On-device sentence vectors via Apple's multilingual contextual embedding (Latin script model,
/// shared space for German and English). Mean-pooled token vectors.
public final class Embedder {
    private let model: NLContextualEmbedding
    private let maxCharacters = 2000

    public init?() {
        guard let model = NLContextualEmbedding(script: .latin) else { return nil }
        self.model = model
    }

    /// Downloads model assets on first use (Apple-hosted, one-time), then loads the model.
    public func prepare() async -> Bool {
        if !model.hasAvailableAssets {
            let result = try? await model.requestAssets()
            guard result == .available else { return false }
        }
        do { try model.load() } catch { return false }
        return true
    }

    public func embed(_ text: String) -> [Float]? {
        let text = String(text.prefix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let result = try? model.embeddingResult(for: text, language: nil) else { return nil }
        var sum = [Double](repeating: 0, count: model.dimension)
        var count = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            for i in 0..<min(vector.count, sum.count) { sum[i] += vector[i] }
            count += 1
            return true
        }
        guard count > 0 else { return nil }
        return sum.map { Float($0 / Double(count)) }
    }
}

enum Vector {
    static func normalized(_ v: [Float]) -> [Float] {
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? v.map { $0 / norm } : v
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        for i in 0..<min(a.count, b.count) { s += a[i] * b[i] }
        return s
    }

    static func mean(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        var m = [Float](repeating: 0, count: first.count)
        for v in vectors { for i in 0..<m.count { m[i] += v[i] } }
        return m.map { $0 / Float(vectors.count) }
    }

    static func subtract(_ a: [Float], _ b: [Float]) -> [Float] {
        zip(a, b).map { $0 - $1 }
    }
}
