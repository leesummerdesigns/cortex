import CortexKit
import Foundation
import Observation
import SwiftUI

/// Runs one agent CLI per message and streams its answer into the open conversation.
@MainActor @Observable
final class ChatController {
    var thread: ChatThread?
    var history: [ChatThread] = []
    var agent: ChatAgent?
    /// nil until checked: true when the agent's CLI is installed and signed in.
    var signedIn: [ChatAgent: Bool] = [:]
    var isRunning = false

    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private let store = ChatStore()
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var didCheck = false

    private func cli(_ agent: ChatAgent) -> URL? {
        guard let connections = model?.connections else { return nil }
        return agent == .claude ? connections.claudeCLI : connections.codexCLI
    }

    var installed: [ChatAgent] { ChatAgent.allCases.filter { cli($0) != nil } }

    /// Finds out once which agents can answer, and picks one that can.
    func prepare() {
        guard !didCheck else { return }
        didCheck = true
        reloadHistory()
        if thread == nil, let latest = history.first { thread = latest; agent = latest.agent }
        if agent == nil { agent = installed.first }
        for candidate in installed {
            guard let url = cli(candidate) else { continue }
            let arguments = candidate == .claude ? ["auth", "status"] : ["login", "status"]
            let environment = Self.environment
            Task.detached {
                let result = Self.run(url, arguments, environment: environment)
                let ok = AgentChat.isSignedIn(candidate, output: result.output, exitCode: result.code)
                await MainActor.run {
                    self.signedIn[candidate] = ok
                    // Don't start on an agent that can't answer when another one can.
                    if self.thread == nil, self.agent != candidate, self.signedIn[self.agent ?? candidate] == false, ok { self.agent = candidate }
                    if self.thread == nil, self.agent == candidate, !ok,
                       let other = self.installed.first(where: { self.signedIn[$0] == true }) { self.agent = other }
                }
            }
        }
    }

    nonisolated private static func run(_ url: URL, _ arguments: [String], environment: [String: String]) -> (output: String, code: Int32) {
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return ("", -1) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
    }

    /// GUI apps start with a bare PATH, and the Codex launcher needs node. A parent Claude session must not leak in.
    private static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE_CODE") && $0.key != "CLAUDECODE" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["MCP_CONNECTION_NONBLOCKING"] = "false" // Claude Code must wait for Cortex, or the first answer has no memory
        env["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        return env
    }

    func newChat() {
        leaveRun()
        thread = nil
    }

    func open(_ chosen: ChatThread) {
        leaveRun()
        thread = chosen
        agent = chosen.agent
    }

    /// Stops a running answer and keeps what arrived so far. Whatever the old run still sends is ignored.
    private func leaveRun() {
        guard isRunning else { return }
        stop()
        process = nil
        isRunning = false
        if let thread { try? store.save(thread) }
        reloadHistory()
    }

    func delete(_ chosen: ChatThread) {
        store.delete(chosen.id)
        if thread?.id == chosen.id { newChat() }
        reloadHistory()
    }

    private func reloadHistory() {
        guard let model else { return }
        history = store.threads(vault: model.vaultURL.standardizedFileURL.path)
    }

    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning, let model, let agent, let url = cli(agent) else { return }

        // A chat belongs to its vault: after switching vaults the next message starts a new one.
        let vaultPath = model.vaultURL.standardizedFileURL.path
        var current = thread.flatMap { $0.vault == vaultPath ? $0 : nil } ?? ChatThread(agent: agent, vault: vaultPath)
        let runID = current.id
        // A session that never started has nothing to resume, so its first message counts again.
        let isFirst = current.session == nil
        let active = CortexConfig.load(vault: model.vaultURL).activePersona
        let personaSwitch = !isFirst && active != current.persona
            ? AgentChat.personaSwitch(to: active.flatMap { id in Packs.installed(vault: model.vaultURL).first { $0.id == id } })
            : nil
        current.persona = active
        current.messages.append(ChatMessage(role: .user, text: text))
        current.messages.append(ChatMessage(role: .assistant, text: ""))
        current.updated = Date()
        thread = current

        let open = model.selectedNote.flatMap { $0.isPrivate || $0.isProposal ? nil : $0.title }
        let prompt = AgentChat.prompt(text, isFirst: isFirst, openNote: open, personaSwitch: personaSwitch)

        let process = Process()
        process.executableURL = url
        process.arguments = AgentChat.arguments(agent: agent, helper: model.helperPath, vault: model.vaultURL.path, session: current.session)
        process.environment = Self.environment
        // Not the vault: its CLAUDE.md is for working on the files, not for this chat.
        let workspace = store.directory.deletingLastPathComponent().appendingPathComponent("chat-workspace")
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        process.currentDirectoryURL = workspace

        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        var parser = AgentStreamParser(agent: agent)
        var buffer = Data()
        func consume(_ data: Data) {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                for event in parser.parse(line) where self.thread?.id == runID { self.apply(event) }
            }
        }

        // Everything below hops to the main queue, which keeps the stream in order.
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { consume(data) } }
        }
        process.terminationHandler = { finished in
            output.fileHandleForReading.readabilityHandler = nil
            let rest = output.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let wasStopped = finished.terminationReason == .uncaughtSignal
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    consume(rest)
                    guard self.process === finished else { return } // the user moved on to another chat
                    self.finish(agent: agent, wasStopped: wasStopped, lastError: parser.lastError ?? stderr)
                }
            }
        }

        do {
            try process.run()
            self.process = process
            isRunning = true
            let handle = input.fileHandleForWriting
            DispatchQueue.global().async {
                try? handle.write(contentsOf: Data(prompt.utf8))
                try? handle.close()
            }
        } catch {
            apply(.failed("Could not start \(agent.name): \(error.localizedDescription)"))
            finish(agent: agent, wasStopped: false, lastError: "")
        }
    }

    func stop() {
        process?.terminate()
    }

    private func apply(_ event: AgentEvent) {
        guard var current = thread, let last = current.messages.indices.last else { return }
        switch event {
        case .session(let id):
            current.session = id
        case .text(let delta):
            current.messages[last].text += delta
        case let .tool(name, detail):
            current.messages[last].tools.append([name, detail].compactMap { $0 }.joined(separator: " · "))
        case .failed(let message):
            current.messages[last].text = message
            current.messages[last].failed = true
        }
        thread = current
    }

    private func finish(agent: ChatAgent, wasStopped: Bool, lastError: String) {
        process = nil
        isRunning = false
        guard var current = thread, let last = current.messages.indices.last else { return }
        if current.messages[last].text.isEmpty, !current.messages[last].failed {
            if wasStopped {
                current.messages[last].text = "Stopped."
                current.messages[last].failed = true // nothing here worth saving
            } else {
                current.messages[last].text = AgentChat.friendlyError(lastError, agent: agent)
                current.messages[last].failed = true
            }
        }
        // The agent may have switched persona itself ("be my editor"); it already has those instructions.
        if current.messages[last].tools.contains(where: { $0.hasPrefix("switch_persona") }) {
            current.persona = CortexConfig.load(vault: URL(fileURLWithPath: current.vault)).activePersona
        }
        current.updated = Date()
        thread = current
        try? store.save(current)
        reloadHistory()
    }

    /// Saves an answer as a normal note in the inbox. Chats are not memory until the user says so.
    func saveToMemory(_ message: ChatMessage) {
        guard let model, let thread else { return }
        let question = thread.messages.last { $0.role == .user && (thread.messages.firstIndex(of: $0) ?? 0) < (thread.messages.firstIndex(of: message) ?? 0) }
        let title = (question?.text ?? thread.title).components(separatedBy: "\n").first ?? thread.title
        do {
            let text = title + "\n" + message.text
            try Capture.save(text, source: "Cortex chat (\(thread.agent.name))", vault: model.vaultURL)
            model.status = "Saved the answer to your inbox"
            Task { await model.reload() }
        } catch {
            model.status = "Could not save: \(error.localizedDescription)"
        }
    }
}

// MARK: - Panel

struct ChatPanel: View {
    @Bindable var model: AppModel
    @State private var draft = ""
    @FocusState private var inputFocused: Bool
    private var chat: ChatController { model.chat }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if chat.installed.isEmpty {
                ContentUnavailableView {
                    Label("No agent found", systemImage: "bubble.left.and.text.bubble.right")
                } description: {
                    Text("The chat uses Claude Code or Codex with the subscription you already have. Install one of them, then open this panel again.")
                }
            } else if let thread = chat.thread, !thread.messages.isEmpty {
                messages(thread)
            } else {
                emptyState
            }
            Divider()
            composer
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "cortex" else { return .systemAction }
            model.handle(url)
            return .handled
        })
        .onAppear {
            chat.prepare()
            inputFocused = true
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(chat.installed) { agent in
                    Button { chat.newChat(); chat.agent = agent } label: {
                        Label(label(agent), systemImage: chat.agent == agent ? "checkmark" : "sparkle")
                    }
                }
            } label: {
                Text(chat.agent?.name ?? "Agent")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Which agent answers. Switching starts a new chat.")
            if let agent = chat.agent, chat.signedIn[agent] == false {
                Text("not signed in").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                if chat.history.isEmpty { Text("No earlier chats") }
                ForEach(chat.history.prefix(20)) { past in
                    Button(past.title) { chat.open(past) }
                }
                if let thread = chat.thread, !thread.messages.isEmpty {
                    Divider()
                    Button("Delete this chat", role: .destructive) { chat.delete(thread) }
                }
            } label: {
                Image(systemName: "clock")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Earlier chats")
            Button { chat.newChat(); inputFocused = true } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.borderless)
                .help("New chat")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func label(_ agent: ChatAgent) -> String {
        chat.signedIn[agent] == false ? "\(agent.name) (not signed in)" : agent.name
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer()
            Text("Ask your memory").font(.title3.weight(.semibold))
            Text("Your agent answers from your notes and names its sources. You'll see what it looks up light up on the graph. It can only reach Cortex: no other files, and never your private notes.")
                .font(.callout).foregroundStyle(.secondary)
            if let agent = chat.agent, chat.signedIn[agent] == false {
                Label("Run “\(agent.loginCommand)” in Terminal to sign in.", systemImage: "exclamationmark.circle")
                    .font(.callout)
            }
            ForEach(["What was I working on recently?", "Which decisions should I look at again?", "What do my notes say I should do next?"], id: \.self) { prompt in
                Button { chat.send(prompt) } label: {
                    Text(prompt).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .disabled(chat.agent == nil)
            }
            Spacer()
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func messages(_ thread: ChatThread) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(thread.messages) { message in
                        MessageRow(model: model, message: message, isLive: chat.isRunning && message.id == thread.messages.last?.id)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(14)
                .textSelection(.enabled)
            }
            .onChange(of: thread.messages.last?.text) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: thread.messages.count) { proxy.scrollTo("end", anchor: .bottom) }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask anything about your notes…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($inputFocused)
                .onSubmit(send)
            if chat.isRunning {
                Button { chat.stop() } label: { Image(systemName: "stop.circle.fill").font(.title3) }
                    .buttonStyle(.borderless)
                    .help("Stop")
            } else {
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title3) }
                    .buttonStyle(.borderless)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.agent == nil)
                    .help("Send (Return)")
            }
        }
        .padding(12)
    }

    private func send() {
        guard !chat.isRunning else { return }
        let text = draft
        draft = ""
        chat.send(text)
        inputFocused = true
    }
}

private struct MessageRow: View {
    @Bindable var model: AppModel
    let message: ChatMessage
    let isLive: Bool

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if !message.tools.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(message.tools.enumerated()), id: \.offset) { _, tool in
                            Label(tool, systemImage: "waveform.path.ecg")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                if message.failed {
                    Label(message.text, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                } else if !message.text.isEmpty {
                    MarkdownBody(text: message.text, noteID: { model.index?.find($0)?.id })
                }
                if isLive {
                    ProgressView().controlSize(.small)
                } else if !message.failed, !message.text.isEmpty {
                    Button { model.chat.saveToMemory(message) } label: { Label("Save to memory", systemImage: "square.and.arrow.down") }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
