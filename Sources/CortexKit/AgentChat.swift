import Foundation

/// The coding agents Cortex can talk to from its own chat. Both use the subscription the user is already signed in to.
public enum ChatAgent: String, Codable, CaseIterable, Sendable, Identifiable {
    case claude, codex

    public var id: String { rawValue }
    public var name: String { self == .claude ? "Claude Code" : "Codex" }
    public var loginCommand: String { self == .claude ? "claude auth login" : "codex login" }
}

/// What an agent reports while it answers.
public enum AgentEvent: Equatable, Sendable {
    case session(String)
    case text(String)
    case tool(name: String, detail: String?)
    case failed(String)
}

/// Builds the command lines and reads the streams of the agent CLIs. The agents get the Cortex tools and nothing
/// else: no shell, no file access, no plugins. That keeps the promise that private notes are never shared with an AI.
public enum AgentChat {
    private static let tools = ["get_core", "recall", "read_note", "remember", "switch_persona"]

    /// Features that would give Codex a way around the Cortex tools (the shell, computer control, plugins, …).
    private static let codexDisabled = [
        "shell_tool", "unified_exec", "apps", "plugins", "computer_use", "browser_use", "browser_use_external",
        "in_app_browser", "multi_agent", "code_mode", "image_generation", "hooks", "goals", "tool_suggest",
    ]

    public static func arguments(agent: ChatAgent, helper: String, vault: String, session: String?) -> [String] {
        switch agent {
        case .claude:
            let config = ["mcpServers": ["cortex": ["command": helper, "args": ["mcp", vault]]]]
            let json = (try? JSONSerialization.data(withJSONObject: config, options: [.withoutEscapingSlashes]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            var args = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                        "--strict-mcp-config", "--mcp-config", json,
                        "--tools", "", "--allowedTools", tools.map { "mcp__cortex__\($0)" }.joined(separator: ","),
                        "--setting-sources", ""]
            if let session { args += ["--resume", session] }
            return args
        case .codex:
            var args = ["exec"]
            if session != nil { args.append("resume") }
            args += ["--json", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
                     "-c", "sandbox_mode=\"read-only\"",
                     "-c", "web_search=\"disabled\"",
                     "-c", "mcp_servers.cortex.command=\(tomlString(helper))",
                     "-c", "mcp_servers.cortex.args=[\"mcp\",\(tomlString(vault))]",
                     "-c", "mcp_servers.cortex.default_tools_approval_mode=\"approve\""]
            args += codexDisabled.flatMap { ["--disable", $0] }
            if let session { args.append(session) }
            args.append("-") // the prompt comes from stdin, so it can't be read as a flag or seen in `ps`
            return args
        }
    }

    private static func tomlString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// What the agent receives. The instructions go along with the first message only; a resumed session has them.
    public static func prompt(_ message: String, isFirst: Bool, openNote: String?) -> String {
        var out = ""
        if isFirst {
            out += """
                You are the user's assistant inside Cortex, the app that holds their personal memory. \
                Call get_core at the start of the conversation. Call recall before answering anything that may depend \
                on their notes, projects, history or preferences. Cite every note you use as [[Exact Note Title]]; \
                the app turns those into links. Reply in the language the user writes in. \
                Only call remember when the user asks you to save something. You can't edit files from here.


                """
        }
        if let openNote { out += "(The user has the note [[\(openNote)]] open right now.)\n\n" }
        return out + message
    }

    /// Unwraps the JSON an API error sometimes arrives in, and says what to do about a missing sign-in.
    public static func friendlyError(_ raw: String, agent: ChatAgent) -> String {
        var message = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = message.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let inner = (json["error"] as? [String: Any])?["message"] as? String ?? json["message"] as? String {
            message = inner
        }
        let lower = message.lowercased()
        if ["authenticate", "oauth", "not logged in", "log in", "login", "401"].contains(where: lower.contains) {
            return "\(agent.name) isn't signed in. Run “\(agent.loginCommand)” in Terminal, then try again."
        }
        return message.isEmpty ? "\(agent.name) stopped without an answer." : message
    }

    /// Parses `claude auth status` / `codex login status` output.
    public static func isSignedIn(_ agent: ChatAgent, output: String, exitCode: Int32) -> Bool {
        switch agent {
        case .claude:
            guard let data = output.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return exitCode == 0 }
            return json["loggedIn"] as? Bool ?? false
        case .codex:
            return exitCode == 0 && output.localizedCaseInsensitiveContains("logged in")
                && !output.localizedCaseInsensitiveContains("not logged in")
        }
    }
}

/// Turns the JSON lines of one agent run into events. Keeps the little state the formats need.
public struct AgentStreamParser {
    public let agent: ChatAgent
    /// The last error reported, for runs that end without a clean failure event.
    public private(set) var lastError: String?
    private var hasText = false

    public init(agent: ChatAgent) { self.agent = agent }

    public mutating func parse(_ line: String) -> [AgentEvent] {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return [] }
        return agent == .claude ? parseClaude(type, json) : parseCodex(type, json)
    }

    private mutating func parseClaude(_ type: String, _ json: [String: Any]) -> [AgentEvent] {
        switch type {
        case "system":
            guard json["subtype"] as? String == "init", let id = json["session_id"] as? String else { return [] }
            return [.session(id)]
        case "stream_event":
            guard let event = json["event"] as? [String: Any] else { return [] }
            if event["type"] as? String == "content_block_start",
               (event["content_block"] as? [String: Any])?["type"] as? String == "text", hasText {
                return [.text("\n\n")]
            }
            guard event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return [] }
            hasText = true
            return [.text(text)]
        case "assistant":
            // Text arrives through the deltas above; complete messages only add the tool calls.
            let content = (json["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return content.compactMap { block in
                guard block["type"] as? String == "tool_use", let name = block["name"] as? String else { return nil }
                return .tool(name: name.replacingOccurrences(of: "mcp__cortex__", with: ""), detail: Self.detail(block["input"]))
            }
        case "result":
            guard json["is_error"] as? Bool == true else { return [] }
            let message = json["result"] as? String ?? (json["errors"] as? [String])?.first ?? ""
            lastError = message
            return [.failed(AgentChat.friendlyError(message, agent: .claude))]
        default:
            return []
        }
    }

    private mutating func parseCodex(_ type: String, _ json: [String: Any]) -> [AgentEvent] {
        switch type {
        case "thread.started":
            return (json["thread_id"] as? String).map { [.session($0)] } ?? []
        case "item.started":
            guard let item = json["item"] as? [String: Any], item["type"] as? String == "mcp_tool_call",
                  let tool = item["tool"] as? String else { return [] }
            return [.tool(name: tool, detail: Self.detail(item["arguments"]))]
        case "item.completed":
            guard let item = json["item"] as? [String: Any], item["type"] as? String == "agent_message",
                  let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return [] }
            defer { hasText = true }
            return [.text((hasText ? "\n\n" : "") + text)]
        case "error":
            lastError = json["message"] as? String // may be a retry notice: only final if the run then fails
            return []
        case "turn.failed":
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? lastError ?? ""
            return [.failed(AgentChat.friendlyError(message, agent: .codex))]
        default:
            return []
        }
    }

    /// The part of a tool call worth showing: the search or the note it asked for.
    private static func detail(_ input: Any?) -> String? {
        guard let input = input as? [String: Any] else { return nil }
        return (input["query"] ?? input["note"] ?? input["title"] ?? input["persona"]) as? String
    }
}

// MARK: - Conversations

public struct ChatMessage: Codable, Sendable, Identifiable, Equatable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public var id = UUID()
    public let role: Role
    public var text: String
    /// “recall · Projekt Falke”: what the agent looked up on the way to this answer.
    public var tools: [String] = []
    public var failed = false

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

/// One conversation. Kept outside the vault: chats are not notes until the user saves one.
public struct ChatThread: Codable, Sendable, Identifiable, Equatable {
    public var id = UUID()
    public var agent: ChatAgent
    public var vault: String
    public var session: String?
    public var messages: [ChatMessage] = []
    public var updated = Date()

    public init(agent: ChatAgent, vault: String) {
        self.agent = agent
        self.vault = vault
    }

    public var title: String {
        let first = messages.first { $0.role == .user }?.text ?? "New chat"
        return String(first.split(separator: "\n").first ?? "New chat").prefix(50).description
    }
}

public struct ChatStore: Sendable {
    public let directory: URL

    public init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Cortex/chats")) {
        self.directory = directory
    }

    public func save(_ thread: ChatThread) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(thread).write(to: url(thread.id), options: [.atomic])
    }

    /// This vault's conversations, newest first.
    public func threads(vault: String) -> [ChatThread] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? decoder.decode(ChatThread.self, from: $0) } }
            .filter { $0.vault == vault }
            .sorted { $0.updated > $1.updated }
    }

    public func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(id))
    }

    private func url(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }
}
