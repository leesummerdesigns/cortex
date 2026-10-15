import AppKit
import CortexKit
import SwiftUI

/// One-click connection of the memory (and personas) into the AI apps the user already uses.
struct ConnectPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        let c = model.connection
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Bring your memory into your AI").font(.headline)
                    Text("Connected apps can load your core and active persona, search your memories and propose new ones. Everything runs on this Mac; private notes never leave it.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("Your memory") {
                HStack(spacing: 10) {
                    Image(systemName: Vault.isInICloud(model.vaultURL) ? "icloud" : "folder").frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.vaultURL.lastPathComponent).font(.callout.weight(.semibold))
                        Text(model.vaultURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Change…") { model.chooseVault() }.controlSize(.small)
                }
                .padding(.vertical, 3)
                Label(Vault.isInICloud(model.vaultURL)
                      ? "In iCloud Drive: install Cortex on your other Macs and choose this same folder."
                      : "Other Macs: move this folder to iCloud Drive (or Dropbox), then choose it here and on each Mac.",
                      systemImage: "laptopcomputer.and.iphone")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("On this Mac") {
                AppRow(name: "Claude Desktop", appPath: "/Applications/Claude.app", installed: c.claudeDesktopInstalled,
                       connected: c.claudeDesktop, detail: "Claude asks you to confirm the install.") {
                    if c.claudeDesktop {
                        Button("Manage…") { model.openClaudeDesktopExtensions() }
                    } else {
                        Button("Connect") { model.connectClaudeDesktop() }.buttonStyle(.borderedProminent)
                    }
                }

                AppRow(name: "Claude Code", appPath: nil, installed: c.claudeCodeInstalled,
                       connected: c.claudeCode, detail: "Available in every project.") {
                    if c.claudeCodeInstalled {
                        ConnectButton(connected: c.claudeCode) { model.setClaudeCode(!c.claudeCode) }
                    } else {
                        Button("Copy command") { model.copy(model.claudeCodeCommand, "Claude Code command") }
                    }
                }
                if c.claudeCode {
                    Toggle(isOn: Binding(get: { c.sessionHook }, set: { model.setSessionHook($0) })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Load my core in every session")
                            Text("Guaranteed, instead of when Claude decides to ask.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .padding(.leading, 38)
                }

                AppRow(name: "Cursor", appPath: "/Applications/Cursor.app", installed: c.cursorInstalled,
                       connected: c.cursor, detail: "Restart Cursor after connecting.") {
                    ConnectButton(connected: c.cursor) { model.setCursor(!c.cursor) }
                }

                HStack {
                    Image(systemName: "puzzlepiece.extension").frame(width: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Other MCP apps").font(.callout.weight(.semibold))
                        Text("Windsurf, VS Code, Zed, … — paste into the app's MCP settings.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Copy config") { model.copy(model.mcpJSON, "MCP config") }
                }
                .padding(.vertical, 3)
            }
            .disabled(model.connectBusy)

            Section("Using personas in your AI") {
                Label("Just ask: “switch to the editor”, “coach me on this”, “no persona”.", systemImage: "text.bubble")
                Label("Claude Desktop: + menu → Cortex → pick a persona.", systemImage: "plus.circle")
                Label("Claude Code: type /mcp__cortex__ and pick a persona.", systemImage: "terminal")
                Label("Or switch here with the persona menu in the toolbar.", systemImage: "theatermasks")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            BridgeSection(model: model)
        }
        .listStyle(.inset)
        .onAppear { model.refreshConnections() }
    }
}

private struct AppRow<Actions: View>: View {
    let name: String
    let appPath: String?
    let installed: Bool
    let connected: Bool
    let detail: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.callout.weight(.semibold))
                HStack(spacing: 4) {
                    Circle().fill(connected ? Color(hex: "#6cc3a0") : .secondary.opacity(0.4)).frame(width: 6, height: 6)
                    Text(connected ? "Connected" : installed ? "Not connected" : "Not installed")
                        .font(.caption).foregroundStyle(connected ? Color(hex: "#6cc3a0") : .secondary)
                }
                if !connected && installed { Text(detail).font(.caption2).foregroundStyle(.tertiary) }
            }
            Spacer()
            if installed || name == "Claude Code" { actions.controlSize(.small) }
        }
        .padding(.vertical, 3)
        .opacity(installed ? 1 : 0.55)
    }

    @ViewBuilder
    private var icon: some View {
        if let appPath, FileManager.default.fileExists(atPath: appPath) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: appPath)).resizable()
        } else {
            Image(systemName: "terminal").font(.title3).foregroundStyle(.secondary)
        }
    }
}

private struct ConnectButton: View {
    let connected: Bool
    let action: () -> Void

    var body: some View {
        if connected {
            Button("Disconnect", action: action).buttonStyle(.bordered)
        } else {
            Button("Connect", action: action).buttonStyle(.borderedProminent)
        }
    }
}

/// Phone, claude.ai on the web, ChatGPT and other computers — through a secure tunnel to this Mac.
private struct BridgeSection: View {
    @Bindable var model: AppModel

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { model.bridgePhase != .off && !isFailed },
                                 set: { $0 ? model.startBridge() : model.stopBridge() })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bridge").font(.callout.weight(.semibold))
                    Text(statusText).font(.caption).foregroundStyle(statusColor)
                }
            }
            .toggleStyle(.switch)

            if let url = model.bridgeURL {
                VStack(alignment: .leading, spacing: 10) {
                    field("Connector URL", "\(url)/mcp") { model.copy("\(url)/mcp", "connector URL") }
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pairing code").font(.caption).foregroundStyle(.secondary)
                            Text(model.bridge.pairingCode)
                                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button("New code") { model.newPairingCode() }.controlSize(.small)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        step(1, "On claude.ai: Settings → Connectors → Add custom connector")
                        step(2, "Paste the connector URL, click Add, then Connect")
                        step(3, "Enter the pairing code — done. Claude on your phone gets it too.")
                    }
                    Text("ChatGPT: Settings → Apps & Connectors → Advanced → Developer mode → Create (depends on your plan).")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            }

            if !model.bridge.pairedDevices.isEmpty {
                ForEach(model.bridge.pairedDevices, id: \.id) { device in
                    HStack {
                        Image(systemName: "iphone.and.arrow.forward").frame(width: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(device.client.name).font(.callout)
                            Text(device.lastUsed.map { "Last used \($0.formatted(.relative(presentation: .named)))" } ?? "Paired")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove") { model.revokeDevice(device.id) }.controlSize(.small)
                    }
                }
            }
        } header: {
            Text("Phone, web & other computers")
        } footer: {
            Text("Prototype: works while this Mac is awake, and the address changes when the Bridge restarts (add the connector again). Private notes are never shared.")
                .font(.caption2)
        }
    }

    private var isFailed: Bool { if case .failed = model.bridgePhase { return true } else { return false } }

    private var statusText: String {
        switch model.bridgePhase {
        case .off: "Use your memory in Claude on the web and phone, ChatGPT and other computers"
        case .starting: "Starting secure tunnel…"
        case .online: model.bridge.pairedDevices.isEmpty ? "Online — pair your first device" : "Online · \(model.bridge.pairedDevices.count) device(s)"
        case .failed(let message): message
        }
    }

    private var statusColor: Color {
        switch model.bridgePhase {
        case .online: Color(hex: "#6cc3a0")
        case .failed: Color(hex: "#ff8a80")
        default: .secondary
        }
    }

    private func field(_ label: String, _ value: String, copy: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(value)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                Button("Copy", action: copy).controlSize(.small)
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.caption.monospacedDigit().weight(.semibold))
                .frame(width: 16, height: 16).background(Circle().fill(.white.opacity(0.1)))
            Text(text).font(.caption)
        }
    }
}

