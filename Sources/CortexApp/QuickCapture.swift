import AppKit
import Carbon.HIToolbox
import CortexKit
import SwiftUI

/// A small floating window for getting a thought down from anywhere: Control-Option-N, even while another app is in front.
@MainActor
final class QuickCapture {
    static let shared = QuickCapture()
    private var panel: NSPanel?
    private weak var model: AppModel?
    private var hotKey: EventHotKeyRef?

    /// Accepts keyboard input without pulling the rest of Cortex in front of what the user was doing.
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    func install(model: AppModel) {
        self.model = model
        guard hotKey == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { QuickCapture.shared.toggle() } }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4358_5458), id: 1) // "CXTX"
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { model.status = "Quick Capture shortcut ⌃⌥N is taken by another app. Use File › Quick Capture." }
    }

    func toggle() {
        if panel?.isVisible == true { close() } else { show() }
    }

    func show(text: String = "") {
        guard let model else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: QuickCaptureView(model: model, text: text) { [weak self] in self?.close() }
            .preferredColorScheme(.dark))
        panel.setContentSize(NSSize(width: 560, height: 340))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 340),
                          styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Quick Capture"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }
}

private struct QuickCaptureView: View {
    @Bindable var model: AppModel
    @State var text: String
    let onClose: () -> Void

    @State private var isDecision = false
    @State private var why = ""
    @State private var alternatives = ""
    @State private var revisitMonths = 3
    @State private var fileInSuggestion = false
    @State private var related: [Note] = []
    @State private var suggestion: String?
    @State private var failure: String?
    @FocusState private var focused: Bool

    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Kind", selection: $isDecision) {
                Text("Note").tag(false)
                Text("Decision").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)

            TextField(isDecision ? "What did you decide?" : "What's on your mind? The first line becomes the title.", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.title3)
                .lineLimit(isDecision ? 2...3 : 4...7)
                .focused($focused)

            if isDecision {
                TextField("Why? Your future self will ask.", text: $why, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...3)
                TextField("What else did you consider?", text: $alternatives)
                    .textFieldStyle(.plain)
                Picker("Look at it again", selection: $revisitMonths) {
                    Text("Never").tag(0)
                    Text("In 1 month").tag(1)
                    Text("In 3 months").tag(3)
                    Text("In 6 months").tag(6)
                }
                .fixedSize()
            }

            Spacer(minLength: 0)

            if !related.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Already in your memory").font(.caption).foregroundStyle(.secondary)
                    ForEach(related) { note in
                        Button { text += text.hasSuffix("\n") || text.isEmpty ? "[[\(note.title)]]" : " [[\(note.title)]]" } label: {
                            HStack(spacing: 6) {
                                LayerDot(layer: note.layer, size: 6, hex: model.dotHex(note))
                                Text(note.title).lineLimit(1)
                                Image(systemName: "link").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Link to this note")
                    }
                }
            }

            HStack(spacing: 10) {
                if let suggestion {
                    Toggle(isOn: $fileInSuggestion) { Text("File in \(suggestion)").lineLimit(1) }
                        .toggleStyle(.checkbox)
                        .help("Goes to your inbox if you leave this off")
                } else {
                    Text("Goes to your inbox").font(.caption).foregroundStyle(.secondary)
                }
                if let failure { Text(failure).font(.caption).foregroundStyle(.red).lineLimit(1) }
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(isEmpty)
                    .help("⌘Return")
            }
        }
        .padding(18)
        .frame(width: 560, height: 340)
        .onAppear { focused = true }
        .task(id: text) {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let index = model.index else { return }
            related = isEmpty ? [] : index.recall(text, limit: 3).compactMap { index.note($0.id) }.filter { $0.pack == nil }
            suggestion = isEmpty ? nil : index.suggestFolder(for: text)
        }
    }

    private func save() {
        guard !isEmpty else { return }
        let decision = isDecision ? Capture.Decision(
            why: why, alternatives: alternatives,
            revisit: revisitMonths > 0 ? Calendar.current.date(byAdding: .month, value: revisitMonths, to: Date()) : nil
        ) : nil
        do {
            try Capture.save(text, decision: decision, folder: fileInSuggestion ? suggestion : nil, vault: model.vaultURL)
            model.status = "Captured"
            Task { await model.reload() }
            onClose()
        } catch {
            failure = error.localizedDescription
        }
    }
}
