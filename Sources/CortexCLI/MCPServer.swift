import CortexKit
import Foundation

/// Minimal MCP server (JSON-RPC 2.0, newline-delimited over stdio).
/// Tools: get_core, recall, read_note, remember. Private notes and pending proposals are never returned.
final class MCPServer {
    private let vault: URL
    private var index: Index?
    private var signature = ""
    var client = "AI"

    init(vault: URL) { self.vault = vault }

    /// Client name used in the activity log; the Bridge sets it from the paired device.
    var clientSuffix = ""

    /// stdio transport: one JSON-RPC message per line.
    func run() async {
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let response = await respond(to: request) { send(response) }
        }
    }

    /// Handles one JSON-RPC message (shared by stdio and the HTTP Bridge). Notifications return nil.
    func respond(to request: [String: Any]) async -> [String: Any]? {
        guard let id = request["id"] else { return nil }
        let method = request["method"] as? String ?? ""
        let params = request["params"] as? [String: Any] ?? [:]
        do {
            return ["jsonrpc": "2.0", "id": id, "result": try await handle(method, params)]
        } catch let error as RPCError {
            return ["jsonrpc": "2.0", "id": id, "error": ["code": error.code, "message": error.message]]
        } catch {
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32603, "message": error.localizedDescription]]
        }
    }

    private struct RPCError: Error { let code: Int; let message: String }

    private func handle(_ method: String, _ params: [String: Any]) async throws -> Any {
        switch method {
        case "initialize":
            if let info = params["clientInfo"] as? [String: Any], let name = info["name"] as? String { client = name + clientSuffix }
            return [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [:], "prompts": [:]],
                "serverInfo": serverInfo(),
                "instructions": instructions(),
            ]
        case "ping":
            return [:] as [String: Any]
        case "tools/list":
            return ["tools": Self.tools]
        case "prompts/list":
            return ["prompts": prompts()]
        case "prompts/get":
            return try prompt(params["name"] as? String ?? "")
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            let text = try await call(name, args)
            return ["content": [["type": "text", "text": text]], "isError": false]
        default:
            throw RPCError(code: -32601, message: "Method not found: \(method)")
        }
    }

    private func call(_ tool: String, _ args: [String: Any]) async throws -> String {
        let index = try await currentIndex()
        switch tool {
        case "get_core":
            ActivityLog.append(ActivityEvent(client: client, kind: .core,
                                             hits: index.notes.filter { $0.layer == .core && !$0.isPrivate }.map { Hit(id: $0.id, score: 1) }, vault: vault))
            return index.coreBundle() + personaFooter()

        case "switch_persona":
            let ref = (args["persona"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            var config = CortexConfig.load(vault: vault)
            if ["", "none", "off", "me", "just me", "default"].contains(ref.lowercased()) {
                config.activePersona = nil
                try config.save(vault: vault)
                return "Persona turned off. Work with the user as yourself, guided only by their core memory."
            }
            guard let pack = Packs.persona(ref, vault: vault) else {
                throw RPCError(code: -32602, message: "No installed persona matches “\(ref)”. \(personaFooter())")
            }
            config.activePersona = pack.id
            try config.save(vault: vault)
            return "Persona switched to \(pack.manifest.name). From now on, follow these instructions:\n\n" + personaText(pack)

        case "recall":
            guard let query = args["query"] as? String, !query.isEmpty else { throw RPCError(code: -32602, message: "query is required") }
            let limit = min(12, max(1, args["limit"] as? Int ?? 6))
            let hits = index.recall(query, limit: limit, forAI: true)
            ActivityLog.append(ActivityEvent(client: client, kind: .recall, query: query, hits: hits, vault: vault))
            guard !hits.isEmpty else { return "No memories found for “\(query)”." }
            var out = "# Memories for “\(query)”\n"
            for (rank, hit) in hits.enumerated() {
                guard let note = index.note(hit.id) else { continue }
                let body = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
                let excerpt = rank < 3 ? String(body.prefix(2500)) : String(body.prefix(400)) + (body.count > 400 ? " …" : "")
                out += "\n## \(rank + 1). \(note.title)\nid: \(note.id) · relevance \(String(format: "%.2f", hit.score))\n\n\(excerpt)\n"
            }
            out += "\nUse read_note with an id to read a memory in full."
            return out

        case "read_note":
            guard let ref = args["note"] as? String, let note = index.find(ref), !note.isPrivate else {
                throw RPCError(code: -32602, message: "No readable note with that id or title.")
            }
            ActivityLog.append(ActivityEvent(client: client, kind: .read, hits: [Hit(id: note.id, score: 1)], note: note.id, vault: vault))
            return "# \(note.title)\nid: \(note.id) · \(note.folder)\n\n\(note.body)"

        case "remember":
            guard let title = args["title"] as? String, let content = args["content"] as? String else {
                throw RPCError(code: -32602, message: "title and content are required")
            }
            let tags = (args["tags"] as? [String]) ?? []
            let decision = (args["kind"] as? String)?.lowercased() == "decision"
                ? Capture.Decision(why: args["why"] as? String ?? "", alternatives: args["alternatives"] as? String ?? "",
                                   revisit: (args["revisit"] as? String).flatMap(Parser.date))
                : nil
            let url = try Proposals.propose(title: title, content: content, tags: tags, decision: decision, source: client, vault: vault)
            ActivityLog.append(ActivityEvent(client: client, kind: .remember, query: title, note: url.lastPathComponent, vault: vault))
            return "Saved “\(title)” as a proposal in \(url.deletingLastPathComponent().lastPathComponent)/. The user will review it in Cortex before it becomes memory."

        default:
            throw RPCError(code: -32602, message: "Unknown tool: \(tool)")
        }
    }

    /// Public URL of the Cortex icon (set by the Bridge), announced so connector lists show the Cortex logo.
    var iconURL: String?

    private func serverInfo() -> [String: Any] {
        var info: [String: Any] = ["name": "cortex", "title": "Cortex", "version": "0.3"]
        if let iconURL { info["icons"] = [["src": iconURL, "mimeType": "image/png", "sizes": ["512x512"]]] }
        return info
    }

    // MARK: Personas

    private var personas: [InstalledPack] {
        Packs.installed(vault: vault).filter { $0.manifest.kind == .persona }
    }

    private func personaText(_ pack: InstalledPack) -> String {
        Packs.notes(of: pack).map(\.body).joined(separator: "\n\n")
    }

    private func personaFooter() -> String {
        let active = CortexConfig.load(vault: vault).activePersona
        guard !personas.isEmpty else { return "" }
        let list = personas.map { $0.manifest.name + ($0.id == active ? " (active)" : "") }.joined(separator: ", ")
        return "\n---\nInstalled personas: \(list). The user can switch with switch_persona (or “none” to turn it off)."
    }

    private func instructions() -> String {
        let active = CortexConfig.load(vault: vault).activePersona.flatMap { id in personas.first { $0.id == id } }
        return """
            Cortex is the user's personal memory, shared across all their AI tools. \
            Call get_core at the start of a task: it returns who the user is, how they want you to work\
            \(active.map { " and the active persona (\($0.manifest.name))" } ?? ""). \
            Call recall before answering anything that may depend on the user's projects, history, preferences or knowledge. \
            Use remember to propose durable new facts; the user reviews proposals before they become memory. \
            When the user makes a decision, save it with remember and kind “decision”, including why they chose it. \
            If the user asks for a different persona or style (e.g. “be my editor”, “coach me”), call switch_persona.
            """
    }

    /// One prompt to load the core, plus one per installed persona (e.g. /mcp__cortex__socratic-coach in Claude Code).
    private func prompts() -> [[String: Any]] {
        [["name": "core", "title": "My core memory", "description": "Load who I am, how I write and what I care about."]]
            + personas.map { ["name": $0.id, "title": $0.manifest.name, "description": $0.manifest.description] }
    }

    private func prompt(_ name: String) throws -> [String: Any] {
        let index = Index(notes: try Vault.load(vault), vault: vault)
        let text: String
        let description: String
        if name == "core" {
            text = "Here is my core memory from Cortex. Use it for everything in this conversation.\n\n" + index.coreBundle()
            description = "My core memory"
        } else if let pack = personas.first(where: { $0.id == name }) {
            var config = CortexConfig.load(vault: vault)
            config.activePersona = pack.id
            try config.save(vault: vault)
            let ownCore = index.notes.filter { $0.layer == .core && $0.pack == nil && !$0.isPrivate }
                .map { "## \($0.title)\n\n\($0.body.trimmingCharacters(in: .whitespacesAndNewlines))" }
                .joined(separator: "\n\n")
            text = "For this conversation, act as “\(pack.manifest.name)”:\n\n\(personaText(pack))\n\n# Who I am (core memory)\n\n\(ownCore)"
            description = pack.manifest.name
        } else {
            throw RPCError(code: -32602, message: "Unknown prompt: \(name)")
        }
        ActivityLog.append(ActivityEvent(client: client, kind: .core,
                                         hits: index.notes.filter { $0.layer == .core && !$0.isPrivate }.map { Hit(id: $0.id, score: 1) }, vault: vault))
        return ["description": description, "messages": [["role": "user", "content": ["type": "text", "text": text]]]]
    }

    /// Rebuilds the index when anything in the vault changed (cheap: embeddings are cached).
    private func currentIndex() async throws -> Index {
        let sig = Vault.signature(vault)
        if let index, sig == signature { return index }
        let fresh = Index(notes: try Vault.load(vault), vault: vault)
        await fresh.buildEmbeddings()
        index = fresh
        signature = sig
        return fresh
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message), let line = String(data: data, encoding: .utf8) else { return }
        print(line)
        fflush(stdout)
    }

    private static let tools: [[String: Any]] = [
        [
            "name": "get_core",
            "description": "Load the user's core memory: identity, writing style, preferences, goals and the active persona. Call at the start of every task.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
        [
            "name": "recall",
            "description": "Search the user's memory (semantic + keyword, German and English). Use before answering anything that may depend on the user's projects, history, knowledge or preferences.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "What to remember, in natural language."],
                    "limit": ["type": "integer", "description": "Max memories (1–12, default 6)."],
                ],
                "required": ["query"],
            ],
        ],
        [
            "name": "read_note",
            "description": "Read one memory in full by id or title (ids come from recall).",
            "inputSchema": [
                "type": "object",
                "properties": ["note": ["type": "string", "description": "Note id or exact title."]],
                "required": ["note"],
            ],
        ],
        [
            "name": "switch_persona",
            "description": "Switch the persona (how the AI works with the user), e.g. when they say “be my editor” or “coach me”. Use “none” to turn it off. Returns the persona's instructions to follow from now on.",
            "inputSchema": [
                "type": "object",
                "properties": ["persona": ["type": "string", "description": "Persona name or id, or “none”."]],
                "required": ["persona"],
            ],
        ],
        [
            "name": "remember",
            "description": "Propose a new durable memory (a decision, preference, fact or learning). It is saved as a proposal; the user reviews it in Cortex. Keep it atomic: one idea per memory. For a decision, set kind to “decision” and say why it was made, so the reasoning isn't lost.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "Short descriptive title."],
                    "content": ["type": "string", "description": "The memory in Markdown."],
                    "tags": ["type": "array", "items": ["type": "string"]],
                    "kind": ["type": "string", "enum": ["note", "decision"], "description": "“decision” logs the reasoning. Default: note."],
                    "why": ["type": "string", "description": "For a decision: why it was made."],
                    "alternatives": ["type": "string", "description": "For a decision: what else was considered."],
                    "revisit": ["type": "string", "description": "For a decision: the day to look at it again, as yyyy-MM-dd."],
                ],
                "required": ["title", "content"],
            ],
        ],
    ]
}
