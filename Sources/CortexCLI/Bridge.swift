import CortexKit
import Foundation

/// Remote access to the memory for claude.ai (web + mobile), ChatGPT and other computers.
/// MCP over Streamable HTTP, protected by OAuth 2.1 (metadata discovery, dynamic client registration,
/// PKCE). A device is approved by entering the pairing code shown in the Cortex app.
actor Bridge {
    private let vault: URL
    private var authCodes: [String: AuthCode] = [:]
    private var servers: [String: MCPServer] = [:] // per access-token hash
    private var failures: [Date] = []

    private struct AuthCode {
        let clientID: String
        let redirectURI: String
        let challenge: String
        let expires: Date
    }

    /// The Cortex app icon, copied by the app next to the helper (…/Application Support/Cortex/icon.png).
    static let icon: Data? = {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let candidates = [
            exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("icon.png"),   // Application Support/Cortex/bin/cortex
            exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/AppIcon.png"), // Cortex.app/Contents/Helpers/cortex
        ]
        return candidates.lazy.compactMap { try? Data(contentsOf: $0) }.first
    }()

    private static let accessLifetime: TimeInterval = 24 * 3600
    private static let refreshLifetime: TimeInterval = 90 * 24 * 3600

    init(vault: URL) { self.vault = vault }

    func handle(_ req: HTTPRequest) async -> HTTPResponse {
        let base = Self.baseURL(req)
        switch (req.method, req.path) {
        case ("GET", "/favicon.ico"), ("GET", "/favicon.png"), ("GET", "/icon.png"),
             ("GET", "/apple-touch-icon.png"), ("GET", "/apple-touch-icon-precomposed.png"):
            guard let icon = Self.icon else { return HTTPResponse(status: 404) }
            return HTTPResponse(status: 200, headers: ["Content-Type": "image/png", "Cache-Control": "public, max-age=86400"], body: icon)
        case ("GET", "/"):
            return .html(page(title: "Cortex Bridge", body: "<p>This is a private Cortex memory. Add <code>\(base)/mcp</code> as a connector in your AI app.</p>"))
        case ("GET", let p) where p.hasPrefix("/.well-known/oauth-protected-resource"):
            return .json(["resource": "\(base)/mcp", "authorization_servers": [base], "bearer_methods_supported": ["header"],
                          "resource_name": "Cortex memory"])
        case ("GET", let p) where p.hasPrefix("/.well-known/oauth-authorization-server") || p.hasPrefix("/.well-known/openid-configuration"):
            return .json([
                "issuer": base,
                "authorization_endpoint": "\(base)/authorize",
                "token_endpoint": "\(base)/token",
                "registration_endpoint": "\(base)/register",
                "response_types_supported": ["code"],
                "grant_types_supported": ["authorization_code", "refresh_token"],
                "code_challenge_methods_supported": ["S256"],
                "token_endpoint_auth_methods_supported": ["none"],
                "scopes_supported": ["memory"],
            ])
        case ("POST", "/register"):
            return register(req)
        case ("GET", "/authorize"):
            return authorizePage(req.query, error: nil)
        case ("POST", "/authorize"):
            return authorize(req.form)
        case ("POST", "/token"):
            return token(req.form)
        case ("POST", "/mcp"), ("POST", "/"):
            return await mcp(req, base: base)
        case ("GET", "/mcp"), ("DELETE", "/mcp"):
            return HTTPResponse(status: 405, headers: ["Allow": "POST"])
        default:
            return HTTPResponse(status: 404)
        }
    }

    // MARK: OAuth

    /// RFC 7591 dynamic client registration (public clients, PKCE only).
    private func register(_ req: HTTPRequest) -> HTTPResponse {
        guard let body = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
              let redirects = body["redirect_uris"] as? [String], !redirects.isEmpty,
              redirects.allSatisfy({ $0.hasPrefix("https://") || $0.hasPrefix("http://localhost") || $0.hasPrefix("http://127.0.0.1") })
        else { return .json(["error": "invalid_client_metadata"], status: 400) }
        let id = "cortex-" + BridgeStore.newSecret().prefix(16)
        let name = (body["client_name"] as? String).map { String($0.prefix(60)) } ?? "AI app"
        BridgeStore.update { $0.clients[id] = BridgeState.Client(name: name, redirectURIs: redirects, created: Date()) }
        return .json([
            "client_id": id, "client_id_issued_at": Int(Date().timeIntervalSince1970), "client_name": name,
            "redirect_uris": redirects, "token_endpoint_auth_method": "none",
            "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
        ], status: 201)
    }

    private func authorizePage(_ q: [String: String], error: String?) -> HTTPResponse {
        guard let clientID = q["client_id"], let client = BridgeStore.load().clients[clientID],
              let redirect = q["redirect_uri"], client.redirectURIs.contains(redirect),
              q["response_type"] == "code", let challenge = q["code_challenge"], !challenge.isEmpty,
              (q["code_challenge_method"] ?? "S256") == "S256"
        else { return .html(page(title: "Invalid request", body: "<p>This sign-in link is invalid or expired. Start again from your AI app.</p>"), status: 400) }

        let hidden = ["client_id", "redirect_uri", "code_challenge", "state", "scope", "resource", "response_type"]
            .compactMap { k in q[k].map { "<input type=\"hidden\" name=\"\(k)\" value=\"\(escape($0))\">" } }.joined()
        let body = """
            <p><b>\(escape(client.name))</b> wants to use your Cortex memory: your core, your active persona and memory search. Private notes are never shared.</p>
            <p>Enter the pairing code shown in <b>Cortex → Connect → Bridge</b> on your Mac:</p>
            <form method="post" action="/authorize">\(hidden)
              <input name="pairing_code" placeholder="XXXX-XXXX" autocomplete="one-time-code" autofocus required>
              \(error.map { "<p class=\"err\">\(escape($0))</p>" } ?? "")
              <button type="submit">Allow access</button>
            </form>
            """
        return .html(page(title: "Connect to Cortex", body: body))
    }

    private func authorize(_ form: [String: String]) -> HTTPResponse {
        guard let clientID = form["client_id"], let redirect = form["redirect_uri"], let challenge = form["code_challenge"],
              let client = BridgeStore.load().clients[clientID], client.redirectURIs.contains(redirect)
        else { return authorizePage(form, error: nil) }

        failures.removeAll { $0 < Date().addingTimeInterval(-600) }
        guard failures.count < 5 else { return authorizePage(form, error: "Too many wrong codes. Try again in 10 minutes.") }

        let entered = (form["pairing_code"] ?? "").uppercased().filter { $0.isLetter || $0.isNumber }
        let expected = BridgeStore.load().pairingCode.filter { $0.isLetter || $0.isNumber }
        guard Self.constantTimeEqual(entered, expected) else {
            failures.append(Date())
            return authorizePage(form, error: "That code doesn't match. Check Cortex on your Mac.")
        }
        // One code, one device: rotate it so it can't be reused.
        BridgeStore.update { $0.pairingCode = BridgeStore.newPairingCode() }

        let code = BridgeStore.newSecret()
        authCodes[code] = AuthCode(clientID: clientID, redirectURI: redirect, challenge: challenge, expires: Date().addingTimeInterval(300))
        guard var components = URLComponents(string: redirect) else { return .redirect(redirect) }
        let existing = components.queryItems ?? []
        components.queryItems = existing + [URLQueryItem(name: "code", value: code)]
            + (form["state"].map { [URLQueryItem(name: "state", value: $0)] } ?? [])
        return .redirect(components.string ?? redirect)
    }

    private func token(_ form: [String: String]) -> HTTPResponse {
        switch form["grant_type"] {
        case "authorization_code":
            guard let code = form["code"], let entry = authCodes.removeValue(forKey: code), entry.expires > Date(),
                  entry.clientID == form["client_id"], entry.redirectURI == form["redirect_uri"],
                  let verifier = form["code_verifier"], BridgeStore.pkceMatches(verifier: verifier, challenge: entry.challenge)
            else { return .json(["error": "invalid_grant"], status: 400) }
            return issueTokens(clientID: entry.clientID)

        case "refresh_token":
            let hash = BridgeStore.hash(form["refresh_token"] ?? "")
            let state = BridgeStore.load()
            guard let old = state.tokens.first(where: { $0.hash == hash && $0.kind == .refresh && $0.expires > Date() }),
                  state.clients[old.clientID] != nil
            else { return .json(["error": "invalid_grant"], status: 400) }
            BridgeStore.update { $0.tokens.removeAll { $0.hash == hash } } // rotate
            return issueTokens(clientID: old.clientID)

        default:
            return .json(["error": "unsupported_grant_type"], status: 400)
        }
    }

    private func issueTokens(clientID: String) -> HTTPResponse {
        let access = BridgeStore.newSecret(), refresh = BridgeStore.newSecret()
        let now = Date()
        BridgeStore.update { state in
            state.tokens.removeAll { $0.expires < now }
            state.tokens.append(.init(hash: BridgeStore.hash(access), clientID: clientID, kind: .access, created: now,
                                      expires: now.addingTimeInterval(Self.accessLifetime), lastUsed: now))
            state.tokens.append(.init(hash: BridgeStore.hash(refresh), clientID: clientID, kind: .refresh, created: now,
                                      expires: now.addingTimeInterval(Self.refreshLifetime)))
        }
        return .json(["access_token": access, "token_type": "Bearer", "expires_in": Int(Self.accessLifetime),
                      "refresh_token": refresh, "scope": "memory"])
    }

    // MARK: MCP endpoint

    private func mcp(_ req: HTTPRequest, base: String) async -> HTTPResponse {
        let bearer = req.headers["authorization"].flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil } ?? ""
        let hash = BridgeStore.hash(bearer)
        let state = BridgeStore.load()
        guard !bearer.isEmpty,
              let token = state.tokens.first(where: { $0.hash == hash && $0.kind == .access && $0.expires > Date() }),
              let client = state.clients[token.clientID]
        else {
            var response = HTTPResponse.json(["error": "invalid_token"], status: 401)
            response.headers["WWW-Authenticate"] = "Bearer resource_metadata=\"\(base)/.well-known/oauth-protected-resource\""
            return response
        }
        if (token.lastUsed ?? .distantPast) < Date().addingTimeInterval(-60) {
            BridgeStore.update { s in
                if let i = s.tokens.firstIndex(where: { $0.hash == hash }) { s.tokens[i].lastUsed = Date() }
            }
        }

        let server = servers[hash] ?? {
            let s = MCPServer(vault: vault)
            s.iconURL = Self.icon == nil ? nil : "\(base)/icon.png"
            s.client = client.name + " (remote)"
            s.clientSuffix = " (remote)"
            servers[hash] = s
            return s
        }()

        let json = try? JSONSerialization.jsonObject(with: req.body)
        if let batch = json as? [[String: Any]] {
            var responses: [[String: Any]] = []
            for message in batch { if let r = await server.respond(to: message) { responses.append(r) } }
            return responses.isEmpty ? HTTPResponse(status: 202) : .json(responses)
        }
        guard let message = json as? [String: Any] else { return .json(["error": "invalid JSON-RPC"], status: 400) }
        guard let response = await server.respond(to: message) else { return HTTPResponse(status: 202) }
        var http = HTTPResponse.json(response)
        if message["method"] as? String == "initialize" { http.headers["Mcp-Session-Id"] = UUID().uuidString }
        return http
    }

    // MARK: Helpers

    /// Public base URL as seen by the caller (the tunnel forwards the original Host).
    static func baseURL(_ req: HTTPRequest) -> String {
        let host = req.headers["x-forwarded-host"] ?? req.headers["host"] ?? "127.0.0.1"
        let local = host.hasPrefix("127.0.0.1") || host.hasPrefix("localhost")
        let proto = req.headers["x-forwarded-proto"] ?? (local ? "http" : "https")
        return "\(proto)://\(host)"
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func page(title: String, body: String) -> String {
        """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(title)</title><link rel="icon" type="image/png" href="/favicon.png"><link rel="apple-touch-icon" href="/apple-touch-icon.png"><style>
        :root{color-scheme:dark}body{margin:0;min-height:100vh;display:grid;place-items:center;background:radial-gradient(ellipse at 40% 30%,#3a3938,#141414);
        font:16px/1.5 -apple-system,system-ui,sans-serif;color:#e8e2dc}main{max-width:420px;padding:32px 24px}
        h1{font:600 22px "SF Mono",Menlo,monospace;letter-spacing:.04em;text-transform:uppercase;background:#080808;display:inline-block;padding:4px 10px}
        input[name=pairing_code]{width:100%;box-sizing:border-box;font:600 24px "SF Mono",Menlo,monospace;letter-spacing:.15em;text-transform:uppercase;
        padding:12px;margin:8px 0;border:1px solid #555;border-radius:8px;background:#1d1c1b;color:#fff;text-align:center}
        button{width:100%;padding:12px;border:0;border-radius:8px;background:#ffc21a;color:#111;font-weight:600;font-size:16px}
        .err{color:#ff8a80}code{background:#080808;padding:2px 6px}</style></head>
        <body><main><h1>\(title)</h1>\(body)</main></body></html>
        """
    }
}
