import AppKit
import CortexKit
import Foundation
import Observation
import UniformTypeIdentifiers
import WebKit

@MainActor @Observable
final class AppModel {
    var vaultURL = UserDefaults.standard.string(forKey: "vaultPath").map { URL(fileURLWithPath: $0) } ?? Vault.defaultURL
    var index: Index?
    var status = "Reading vault…"
    var isLoading = true

    enum Panel: String, CaseIterable, Identifiable {
        case note, connect, library, activity, health, style
        var id: String { rawValue }
        var title: String {
            switch self {
            case .note: "Note"
            case .connect: "Connect"
            case .library: "Packs"
            case .activity: "Activity"
            case .health: "Health"
            case .style: "Appearance"
            }
        }
        var icon: String {
            switch self {
            case .note: "doc.text"
            case .connect: "link"
            case .library: "shippingbox"
            case .activity: "waveform.path.ecg"
            case .health: "heart.text.square"
            case .style: "paintpalette"
            }
        }
    }

    var selectedID: String?
    var showInspector = false
    var panel = Panel.note

    // Recall (typed by the user, or replayed from an AI tool)
    var query = ""
    var lastQuery = ""
    var hits: [Hit] = []
    var recallSource: String?

    // Packs & personas
    var config = CortexConfig()
    var installedPacks: [InstalledPack] = []

    // Live activity from AI tools
    var activity: [ActivityEvent] = []
    var toast: ActivityEvent?

    // AI app connections
    struct ConnectionState: Equatable {
        var claudeDesktopInstalled = false, claudeDesktop = false
        var claudeCodeInstalled = false, claudeCode = false, sessionHook = false
        var cursorInstalled = false, cursor = false
        var any: Bool { claudeDesktop || claudeCode || cursor }
    }
    var connection = ConnectionState()
    var connectBusy = false
    @ObservationIgnored let connections = Connections()
    @ObservationIgnored private var stableHelper: URL?

    // Bridge: remote access for claude.ai (web + phone), ChatGPT and other computers
    enum BridgePhase: Equatable { case off, starting, online, failed(String) }
    var bridgePhase = BridgePhase.off
    var bridgeURL: String?
    var bridge = BridgeState()
    @ObservationIgnored private var bridgeServer: Process?
    @ObservationIgnored private var bridgeTunnel: Process?
    private static let bridgePort = "7319"

    // Timeline
    var timelineActive = false {
        didSet { if !timelineActive { stopTimeline(); js("Cortex.setTimeline(null)") } else { setTimeline(timelineEnd) } }
    }
    var timelineDate = Date()
    var isPlayingTimeline = false

    var visibleLayers = Set(Layer.allCases) {
        didSet { js("Cortex.setLayers(\(encode(visibleLayers.map(\.rawValue))))") }
    }

    var style = GraphStyle.load() {
        didSet {
            guard style != oldValue else { return }
            style.save()
            js("Cortex.setStyle(\(encode(style)))")
        }
    }

    @ObservationIgnored weak var webView: WKWebView?
    @ObservationIgnored private var graphReady = false
    @ObservationIgnored private var signature = ""
    @ObservationIgnored private var activityOffset: UInt64 = 0
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var timelineTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    var selectedNote: Note? { selectedID.flatMap { index?.note($0) } }
    var proposals: [Note] { (index?.notes ?? []).filter(\.isProposal) }
    var activePersona: InstalledPack? { installedPacks.first { $0.id == config.activePersona } }

    func notes(in layer: Layer) -> [Note] {
        (index?.notes ?? []).filter { $0.layer == layer && !$0.isProposal }
    }

    // MARK: Loading & live sync

    func load() async {
        isLoading = true
        if !FileManager.default.fileExists(atPath: vaultURL.path) { try? Vault.createStarter(at: vaultURL) }
        installHelper()
        refreshConnections()
        await reload()
        isLoading = false
        bridge = BridgeStore.load()
        if UserDefaults.standard.bool(forKey: "bridgeEnabled") { startBridge() }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopBridge(remember: false) }
        }
        // First launch: nothing connected yet → show how to bring the memory into the user's AI apps.
        if !connection.any && !UserDefaults.standard.bool(forKey: "connectIntroShown") {
            UserDefaults.standard.set(true, forKey: "connectIntroShown")
            panel = .connect
            showInspector = true
        }
        let recent = ActivityLog.recent()
        activity = recent.events.filter(isOurs).reversed()
        activityOffset = recent.offset
        startWatching()
    }

    /// Re-reads the vault (embeddings are cached, so this is fast) and updates the graph in place.
    func reload() async {
        let url = vaultURL
        let pending = Vault.requestDownloads(url)
        do {
            signature = Vault.signature(url)
            config = CortexConfig.load(vault: url)
            installedPacks = Packs.installed(vault: url)
            let notes = try await Task.detached { try Vault.load(url) }.value
            let index = Index(notes: notes, vault: url)
            if self.index == nil { status = "Building neurons…" }
            let embedded = await index.buildEmbeddings()
            self.index = index
            let packCount = notes.filter { $0.pack != nil }.count
            status = "\(notes.count - packCount) notes · \(index.manualLinks.count + index.autoLinks.count) connections"
                + (packCount > 0 ? " · \(packCount) from packs" : "")
                + (embedded ? "" : " · embeddings unavailable")
                + (pending > 0 ? " · downloading \(pending) from iCloud…" : "")
            pushGraph()
        } catch {
            status = "Vault not readable: \(error.localizedDescription)"
        }
    }

    private func startWatching() {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.pollActivity()
                if self.bridgePhase != .off { self.bridge = BridgeStore.load() }
                tick += 1
                if tick % 2 == 0, Vault.signature(self.vaultURL) != self.signature { await self.reload() }
            }
        }
    }

    private func isOurs(_ event: ActivityEvent) -> Bool {
        event.vault == nil || event.vault == vaultURL.standardizedFileURL.path
    }

    private func pollActivity() {
        let (events, offset) = ActivityLog.read(from: activityOffset)
        activityOffset = offset
        for event in events where isOurs(event) {
            activity.insert(event, at: 0)
            if event.kind != .remember { replay(event) } else { showToast(event) }
        }
        if activity.count > 200 { activity.removeLast(activity.count - 200) }
    }

    /// Lights up what an AI tool recalled, as if it had been searched here.
    func replay(_ event: ActivityEvent) {
        let label: String
        switch event.kind {
        case .recall: label = event.query ?? "Recall"
        case .core: label = "Core memory"
        case .read: label = index?.note(event.note ?? "")?.title ?? "Read"
        case .remember: label = event.query ?? "New memory"
        }
        recallSource = event.client
        lastQuery = label
        hits = event.hits
        js("Cortex.recall(\(encode(event.hits)))")
        showToast(event)
    }

    private func showToast(_ event: ActivityEvent) {
        toast = event
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    // MARK: Graph bridge

    func graphDidLoad() {
        graphReady = true
        js("Cortex.setStyle(\(encode(style)))")
        pushGraph()
    }

    private func pushGraph() {
        guard graphReady, let index else { return }
        js("Cortex.setGraph(\(encode(index.graph())))")
        if timelineActive { setTimeline(timelineDate) }
    }

    func select(_ id: String?) {
        selectedID = id
        if let id {
            panel = .note
            showInspector = true
            js("Cortex.select(\(encode(id)))")
        }
    }

    func recall() {
        guard let index else { return }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, q != lastQuery || recallSource != nil else { return }
        lastQuery = q
        recallSource = nil
        hits = index.recall(q)
        js("Cortex.recall(\(encode(hits)))")
    }

    func clearRecall() {
        hits = []
        lastQuery = ""
        recallSource = nil
        js("Cortex.clearRecall()")
    }

    func overview() {
        clearRecall()
        js("Cortex.overview()")
    }

    /// Toolbar / panel switcher: show the panel, or hide the inspector if it is already showing it.
    func toggle(_ target: Panel) {
        if showInspector && panel == target { showInspector = false } else { panel = target; showInspector = true }
    }

    // MARK: Context export

    /// Core + current recall as Markdown on the clipboard, for ChatGPT, Gemini or any tool without MCP.
    func copyContext() {
        guard let index else { return }
        let text = index.contextBundle(query: lastQuery.isEmpty ? "general" : lastQuery, hits: hits)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status = "Copied context to clipboard · ~\(Index.tokens(estimateFor: text)) tokens"
    }

    // MARK: Packs & personas

    func setPersona(_ id: String?) {
        config.activePersona = id
        saveConfigAndReload()
    }

    func setPack(_ id: String, enabled: Bool) {
        config.enabledPacks.removeAll { $0 == id }
        if enabled { config.enabledPacks.append(id) }
        saveConfigAndReload()
    }

    private func saveConfigAndReload() {
        do { try config.save(vault: vaultURL) } catch { status = "Could not save settings: \(error.localizedDescription)" }
        Task { await reload() }
    }

    /// Starter packs bundled with the app (or the repo's Packs/ folder when run from source).
    var starterPacks: [InstalledPack] {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Packs")
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Packs")
        let dir = [bundled, repo].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
        let folders = dir.flatMap { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) } ?? []
        return folders.compactMap { f in Packs.manifest(in: f).map { InstalledPack(manifest: $0, url: f) } }
            .sorted { ($0.manifest.kind.rawValue, $0.manifest.name) < ($1.manifest.kind.rawValue, $1.manifest.name) }
    }

    func install(_ source: URL, activate: Bool = true) {
        do {
            let manifest = try Packs.install(from: source, vault: vaultURL)
            if activate {
                if manifest.kind == .persona { config.activePersona = manifest.id }
                else if !config.enabledPacks.contains(manifest.id) { config.enabledPacks.append(manifest.id) }
            }
            status = "Installed “\(manifest.name)”"
            saveConfigAndReload()
        } catch {
            status = "Install failed: \(error.localizedDescription)"
        }
    }

    func importPack() {
        let panel = NSOpenPanel()
        panel.message = "Choose a Cortex pack (folder with pack.json, or .zip)"
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.zip, .folder]
        if panel.runModal() == .OK, let url = panel.url { install(url) }
    }

    func removePack(_ id: String) {
        do {
            try Packs.remove(id, vault: vaultURL)
            config = CortexConfig.load(vault: vaultURL)
            Task { await reload() }
        } catch {
            status = "Could not remove pack: \(error.localizedDescription)"
        }
    }

    /// Packages the user's own core (style, preferences, identity) as a shareable persona pack.
    func exportCore() {
        let core = (index?.notes ?? []).filter { $0.layer == .core && $0.pack == nil && !$0.isPrivate }
        guard !core.isEmpty else { status = "No core notes to export"; return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "My Core.zip"
        panel.allowedContentTypes = [.zip]
        panel.message = "Export your core memory as a persona pack (\(core.count) notes, private notes excluded)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let manifest = PackManifest(
            id: "core-\(NSUserName().lowercased())", name: "\(NSFullUserName()) — Core", author: NSFullUserName(),
            description: "Identity, writing style and preferences of \(NSFullUserName()).", kind: .persona, color: style.coreColor)
        do {
            try Packs.export(core, manifest: manifest, to: url)
            status = "Exported \(core.count) core notes to \(url.lastPathComponent)"
        } catch {
            status = "Export failed: \(error.localizedDescription)"
        }
    }

    // MARK: Review inbox & privacy

    func accept(_ note: Note) {
        perform("Accepted “\(note.title)”") { try Proposals.accept(note) }
    }

    func discard(_ note: Note) {
        if selectedID == note.id { selectedID = nil }
        perform("Moved “\(note.title)” to the Trash") { try Proposals.discard(note) }
    }

    func setPrivate(_ note: Note, _ isPrivate: Bool) {
        perform(isPrivate ? "“\(note.title)” is now private" : "“\(note.title)” is visible to AI tools") {
            try Proposals.setPrivate(note, isPrivate)
        }
    }

    private func perform(_ message: String, _ action: () throws -> Void) {
        do {
            try action()
            status = message
            Task { await reload() }
        } catch {
            status = error.localizedDescription
        }
    }

    // MARK: Timeline

    var timelineStart: Date {
        (index?.notes ?? []).filter { $0.pack == nil }.map(\.created).filter { $0 > .distantPast }.min() ?? Date()
    }
    var timelineEnd: Date { Date() }

    func setTimeline(_ date: Date) {
        timelineDate = date
        js("Cortex.setTimeline(\((date.timeIntervalSince1970 * 1000).rounded()))")
    }

    /// Plays back by memory, not by calendar: each frame reveals the next notes in creation order,
    /// so years with few notes pass quickly and busy months unfold slowly.
    func playTimeline() {
        stopTimeline()
        isPlayingTimeline = true
        let dates = (index?.notes ?? []).filter { $0.pack == nil }.map(\.created).sorted()
        guard !dates.isEmpty else { isPlayingTimeline = false; return }
        timelineTask = Task { [weak self] in
            let steps = min(240, max(60, dates.count * 3))
            for i in 0...steps {
                guard !Task.isCancelled, let self else { return }
                let position = Double(i) / Double(steps) * Double(dates.count - 1)
                self.setTimeline(dates[Int(position.rounded())])
                try? await Task.sleep(for: .milliseconds(45))
            }
            self?.setTimeline(Date())
            self?.isPlayingTimeline = false
        }
    }

    func stopTimeline() {
        timelineTask?.cancel()
        isPlayingTimeline = false
    }

    // MARK: Vault folder (multi-Mac via iCloud Drive or any synced folder)

    func chooseVault() {
        let panel = NSOpenPanel()
        panel.message = "Choose the folder with your Markdown memory (an Obsidian vault works). Put it in iCloud Drive to share it between Macs."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = vaultURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setVault(url)
    }

    func setVault(_ url: URL) {
        guard url.standardizedFileURL != vaultURL.standardizedFileURL else { return }
        UserDefaults.standard.set(url.path, forKey: "vaultPath")
        vaultURL = url
        selectedID = nil
        clearRecall()
        index = nil
        status = "Reading \(url.lastPathComponent)…"
        // Connected apps point at the old folder — move them along.
        let state = connection
        if state.claudeCode { setClaudeCode(true) }
        if state.sessionHook { setSessionHook(true) }
        if state.cursor { setCursor(true) }
        restartBridgeServer()
        Task {
            await reload()
            let recent = ActivityLog.recent()
            activity = recent.events.filter(isOurs).reversed()
            if state.claudeDesktop { status = "Vault changed — in Claude Desktop, update Cortex's “Memory vault” setting (Settings → Extensions)" }
        }
    }

    // MARK: Bridge

    var cloudflared: URL? {
        ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared"].map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Starts `cortex serve` (OAuth + MCP on 127.0.0.1) and a Cloudflare tunnel that gives it a public HTTPS address.
    func startBridge() {
        guard bridgeServer == nil else { return }
        guard let cloudflared else {
            bridgePhase = .failed("Needs the free Cloudflare tunnel tool: run “brew install cloudflared” in Terminal.")
            return
        }
        UserDefaults.standard.set(true, forKey: "bridgeEnabled")
        bridgePhase = .starting
        bridgeURL = nil
        // A tunnel left over from a crashed or killed Cortex would hold the port; only ours matches this pattern.
        let cleanup = Process()
        cleanup.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        cleanup.arguments = ["-f", "cloudflared tunnel --url http://127.0.0.1:\(Self.bridgePort) "]
        try? cleanup.run()
        cleanup.waitUntilExit()

        let tunnel = Process()
        tunnel.executableURL = cloudflared
        tunnel.arguments = ["tunnel", "--url", "http://127.0.0.1:\(Self.bridgePort)", "--no-autoupdate"]
        let output = Pipe()
        tunnel.standardError = output
        tunnel.standardOutput = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(data: handle.availableData, encoding: .utf8) ?? ""
            guard let range = text.range(of: #"https://[a-z0-9-]+\.trycloudflare\.com"#, options: .regularExpression) else { return }
            let url = String(text[range])
            Task { @MainActor in
                self?.bridgeURL = url
                self?.bridgePhase = .online
                self?.status = "Bridge online — add \(url)/mcp as a connector on claude.ai"
            }
        }
        tunnel.terminationHandler = { [weak self] p in
            Task { @MainActor in
                guard let self, self.bridgeTunnel === p else { return }
                self.stopBridge(remember: true)
                self.bridgePhase = .failed("The tunnel stopped (exit \(p.terminationStatus)). Turn the Bridge on again to retry.")
            }
        }
        do {
            try tunnel.run()
            bridgeTunnel = tunnel
            try launchBridgeServer()
        } catch {
            stopBridge(remember: false)
            bridgePhase = .failed(error.localizedDescription)
        }
    }

    /// The local server can be restarted (crash, update, vault change) while the tunnel — and with it the
    /// public address the user's connectors point to — keeps running.
    private func launchBridgeServer() throws {
        let server = Process()
        server.executableURL = URL(fileURLWithPath: helperPath)
        server.arguments = ["serve", vaultURL.path, Self.bridgePort]
        server.standardOutput = Pipe()
        server.standardError = Pipe()
        server.terminationHandler = { [weak self] p in
            Task { @MainActor in
                guard let self, self.bridgeServer === p, self.bridgeTunnel != nil else { return }
                try? await Task.sleep(for: .seconds(1))
                try? self.launchBridgeServer()
            }
        }
        try server.run()
        bridgeServer = server
    }

    /// Restarts only the local server (e.g. after the vault folder changed); the public address stays the same.
    func restartBridgeServer() {
        guard let old = bridgeServer else { return }
        bridgeServer = nil
        old.terminate()
        try? launchBridgeServer()
    }

    func stopBridge(remember: Bool = true) {
        if remember { UserDefaults.standard.set(false, forKey: "bridgeEnabled") }
        let (server, tunnel) = (bridgeServer, bridgeTunnel)
        bridgeServer = nil
        bridgeTunnel = nil
        (tunnel?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        server?.terminate()
        tunnel?.terminate()
        bridgeURL = nil
        bridgePhase = .off
    }

    func newPairingCode() {
        BridgeStore.update { $0.pairingCode = BridgeStore.newPairingCode() }
        bridge = BridgeStore.load()
    }

    func revokeDevice(_ id: String) {
        BridgeStore.revoke(clientID: id)
        bridge = BridgeStore.load()
        status = "Device removed — it can no longer read your memory"
    }

    // MARK: AI app connections

    private var bundledHelper: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/cortex") }

    /// Stable copy of the MCP helper, so AI apps keep working when Cortex.app moves or updates.
    private func installHelper() {
        guard FileManager.default.fileExists(atPath: bundledHelper.path) else { return }
        stableHelper = try? connections.installHelper(from: bundledHelper)
        // The Bridge serves this as its icon (favicon + MCP server icon), so connectors show the Cortex logo.
        if let icon = Bundle.main.resourceURL?.appendingPathComponent("AppIcon.png"),
           let data = try? Data(contentsOf: icon) {
            try? data.write(to: stableHelper?.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("icon.png")
                            ?? icon, options: .atomic)
        }
    }

    var helperPath: String { (stableHelper ?? bundledHelper).path }

    func refreshConnections() {
        let fm = FileManager.default
        connection = ConnectionState(
            claudeDesktopInstalled: fm.fileExists(atPath: "/Applications/Claude.app"),
            claudeDesktop: connections.claudeDesktopConnected,
            claudeCodeInstalled: connections.claudeCLI != nil,
            claudeCode: connections.claudeCodeConnected,
            sessionHook: connections.sessionHookInstalled,
            cursorInstalled: fm.fileExists(atPath: "/Applications/Cursor.app") || fm.fileExists(atPath: connections.cursorConfig.deletingLastPathComponent().path),
            cursor: connections.cursorConnected
        )
    }

    /// Builds the Cortex extension (.mcpb) and hands it to Claude Desktop, which shows its own install dialog.
    func connectClaudeDesktop() {
        let mcpb = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cortex/Cortex.mcpb")
        let icon = Bundle.main.resourceURL?.appendingPathComponent("AppIcon.png")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3"
        do {
            try Connections.buildMCPB(helper: URL(fileURLWithPath: helperPath), vault: vaultURL, icon: icon,
                                      version: version + ".0", to: mcpb)
            NSWorkspace.shared.open([mcpb], withApplicationAt: URL(fileURLWithPath: "/Applications/Claude.app"),
                                    configuration: NSWorkspace.OpenConfiguration())
            status = "Claude Desktop is asking you to install Cortex — click Install there"
            pollConnections()
        } catch {
            status = "Could not prepare the Claude Desktop extension: \(error.localizedDescription)"
        }
    }

    func openClaudeDesktopExtensions() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Claude.app"))
        status = "In Claude: Settings → Extensions → Cortex → Uninstall"
    }

    func setClaudeCode(_ on: Bool) {
        let (c, helper, vault) = (connections, URL(fileURLWithPath: helperPath), vaultURL)
        runConnection(on ? "Connected Claude Code" : "Disconnected Claude Code") {
            if on { try c.connectClaudeCode(helper: helper, vault: vault) } else { try c.disconnectClaudeCode() }
        }
    }

    func setSessionHook(_ on: Bool) {
        let (c, helper, vault) = (connections, URL(fileURLWithPath: helperPath), vaultURL)
        runConnection(on ? "Claude Code now loads your core in every session" : "Removed the session hook") {
            if on { try c.installSessionHook(helper: helper, vault: vault) } else { try c.removeSessionHook() }
        }
    }

    func setCursor(_ on: Bool) {
        let (c, helper, vault) = (connections, URL(fileURLWithPath: helperPath), vaultURL)
        runConnection(on ? "Connected Cursor — restart Cursor to load Cortex" : "Disconnected Cursor") {
            if on { try c.connectCursor(helper: helper, vault: vault) } else { try c.disconnectCursor() }
        }
    }

    private func runConnection(_ message: String, _ action: @escaping @Sendable () throws -> Void) {
        connectBusy = true
        Task {
            do {
                try await Task.detached { try action() }.value
                status = message
            } catch {
                status = error.localizedDescription
            }
            connectBusy = false
            refreshConnections()
        }
    }

    /// Claude Desktop installs asynchronously after the user confirms; watch for it for a minute.
    private func pollConnections() {
        Task { [weak self] in
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                self.refreshConnections()
                if self.connection.claudeDesktop { self.status = "Claude Desktop is connected to your memory"; return }
            }
        }
    }

    var claudeCodeCommand: String {
        "claude mcp add cortex --scope user -- \"\(helperPath)\" mcp \"\(vaultURL.path)\""
    }

    var mcpJSON: String {
        """
        {
          "mcpServers": {
            "cortex": { "command": "\(helperPath)", "args": ["mcp", "\(vaultURL.path)"] }
          }
        }
        """
    }

    func copy(_ text: String, _ what: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status = "Copied \(what)"
    }

    // MARK: Editing

    func save(_ note: Note, text: String) {
        do {
            try text.write(to: note.url, atomically: true, encoding: .utf8)
            status = "Saved \(note.title)"
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }

    /// cortex://recall?q=…  ·  cortex://open?id=…
    func handle(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        switch url.host {
        case "recall":
            query = value("q") ?? ""
            recall()
        case "open":
            select(value("id"))
        default:
            break
        }
    }

    // MARK: Helpers

    private func js(_ script: String) {
        guard graphReady else { return }
        webView?.evaluateJavaScript(script) { _, error in
            if let error { print("[graph] \(error)") }
        }
    }

    private func encode<T: Encodable>(_ value: T) -> String {
        (try? String(data: JSONEncoder().encode(value), encoding: .utf8)) ?? "null"
    }
}
