import CryptoKit
import Foundation

/// State of the Bridge (remote access for claude.ai, phones, other computers), shared between the app
/// (shows pairing code, devices, revoke) and the `cortex serve` process (OAuth + MCP over HTTPS).
/// Tokens are stored only as SHA-256 hashes.
public struct BridgeState: Codable, Sendable {
    public struct Client: Codable, Sendable {
        public var name: String
        public var redirectURIs: [String]
        public var created: Date

        public init(name: String, redirectURIs: [String], created: Date) {
            self.name = name
            self.redirectURIs = redirectURIs
            self.created = created
        }
    }

    public struct Token: Codable, Sendable {
        public enum Kind: String, Codable, Sendable { case access, refresh }
        public var hash: String
        public var clientID: String
        public var kind: Kind
        public var created: Date
        public var expires: Date
        public var lastUsed: Date?

        public init(hash: String, clientID: String, kind: Kind, created: Date, expires: Date, lastUsed: Date? = nil) {
            self.hash = hash
            self.clientID = clientID
            self.kind = kind
            self.created = created
            self.expires = expires
            self.lastUsed = lastUsed
        }
    }

    /// Shown in the Cortex app; required to approve a new device. Rotates after every successful pairing.
    public var pairingCode: String = BridgeStore.newPairingCode()
    public var clients: [String: Client] = [:]
    public var tokens: [Token] = []

    public init() {}

    /// Devices that currently hold a valid token, newest activity first.
    public var pairedDevices: [(id: String, client: Client, lastUsed: Date?)] {
        let now = Date()
        let live = Dictionary(grouping: tokens.filter { $0.expires > now }, by: \.clientID)
        return live.compactMap { id, tokens in
            clients[id].map { (id, $0, tokens.compactMap(\.lastUsed).max()) }
        }.sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
    }
}

public enum BridgeStore {
    public static var url: URL {
        if let override = ProcessInfo.processInfo.environment["CORTEX_BRIDGE_STORE"] { return URL(fileURLWithPath: override) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cortex/bridge.json")
    }

    public static func load() -> BridgeState {
        guard let data = try? Data(contentsOf: url), let state = try? decoder.decode(BridgeState.self, from: data) else {
            return BridgeState()
        }
        return state
    }

    public static func save(_ state: BridgeState) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Read-modify-write (the app and the serve process both write this file).
    public static func update(_ change: (inout BridgeState) -> Void) {
        var state = load()
        change(&state)
        save(state)
    }

    /// Removes a device: its tokens stop working immediately.
    public static func revoke(clientID: String) {
        update { state in
            state.tokens.removeAll { $0.clientID == clientID }
            state.clients.removeValue(forKey: clientID)
        }
    }

    /// 8 characters from an unambiguous alphabet, shown as XXXX-XXXX.
    public static func newPairingCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let chars = (0..<8).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] }
        return String(chars[0..<4]) + "-" + String(chars[4..<8])
    }

    /// 256-bit random token, base64url.
    public static func newSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return base64url(Data(bytes))
    }

    public static func hash(_ secret: String) -> String {
        SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// PKCE S256: BASE64URL(SHA256(verifier)) == challenge.
    public static func pkceMatches(verifier: String, challenge: String) -> Bool {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8)))) == challenge
    }

    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
