import CortexKit
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            HStack(spacing: 0) {
            ZStack {
                Theme.field
                GraphView(model: model)
                    .clipped()
                if model.isLoading {
                    LoadingOverlay(status: model.status)
                }
                VStack(spacing: 12) {
                    HStack {
                        Spacer()
                        if let toast = model.toast { ToastView(model: model, event: toast) }
                    }
                    Spacer()
                    HStack(alignment: .bottom) {
                        if !model.lastQuery.isEmpty { RecallPanel(model: model) }
                        Spacer()
                    }
                    if model.timelineActive { TimelineBar(model: model) }
                }
                .padding(16)
                .animation(.spring(duration: 0.35), value: model.toast)
            }
            // Laid out by hand instead of .inspector, which overlays the graph when space is tight.
            if model.showInspector {
                Divider()
                InspectorContainer(model: model)
                    .frame(width: 390)
                    .background(.background)
            }
            }
            .navigationTitle("Cortex")
            .navigationSubtitle(model.status)
            .toolbar {
                ToolbarItem {
                    Button { QuickCapture.shared.toggle() } label: { Label("Quick Capture", systemImage: "plus.bubble") }
                        .help("Get a thought down (⌃⌥N from anywhere)")
                }
                ToolbarItem {
                    Button { model.toggle(.chat) } label: { Label("Chat", systemImage: "bubble.left.and.text.bubble.right") }
                        .help("Ask your memory through your connected agent")
                }
                ToolbarItem { PersonaMenu(model: model) }
                ToolbarItem {
                    Toggle(isOn: $model.timelineActive) { Label("Timeline", systemImage: "clock.arrow.circlepath") }
                        .help("Watch your memory grow over time")
                }
                ToolbarItem {
                    Button { model.overview() } label: { Label("Overview", systemImage: "scope") }
                        .help("Show the whole network")
                }
                ToolbarItem {
                    Button { model.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                        .help("Note, packs, activity, health and appearance")
                }
            }
        }
        .searchable(text: $model.query, placement: .toolbar, prompt: "Search memories")
        .onSubmit(of: .search) { model.recall() }
        .task(id: model.query) {
            // Live recall while typing, debounced.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            if model.query.trimmingCharacters(in: .whitespaces).count >= 3 { model.recall() }
            else if !model.lastQuery.isEmpty && model.recallSource == nil { model.clearRecall() }
        }
        .onKeyPress(.escape) {
            model.clearRecall()
            return .handled
        }
        .environment(\.graphStyle, model.style)
        .task { await model.load() }
        .onOpenURL { model.handle($0) }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
            Section("Layers") {
                ForEach(Layer.allCases, id: \.self) { layer in
                    Toggle(isOn: Binding(
                        get: { model.visibleLayers.contains(layer) },
                        set: { on in
                            if on { model.visibleLayers.insert(layer) } else { model.visibleLayers.remove(layer) }
                        }
                    )) {
                        HStack(spacing: 8) {
                            LayerDot(layer: layer)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(Theme.name(layer))
                                Text(Theme.caption(layer)).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(model.notes(in: layer).count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }

            if !model.groups.isEmpty {
                Section("Groups") {
                    ForEach(model.groups, id: \.self) { group in
                        let notes = model.notes(inGroup: group)
                        DisclosureGroup {
                            ForEach(notes) { note in
                                Text(note.title).lineLimit(1).tag(note.id)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                LayerDot(layer: .memory, hex: model.groupColor(group))
                                Text(group)
                                Spacer()
                                Text("\(notes.count)").foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                }
            }

            if !model.decisions.isEmpty {
                Section("Decisions") {
                    ForEach(model.decisions) { note in
                        HStack(spacing: 8) {
                            LayerDot(layer: note.layer, size: 6, hex: model.dotHex(note))
                            Text(note.title).lineLimit(1)
                            if let revisit = note.revisit {
                                Spacer()
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.caption2)
                                    .foregroundStyle(revisit <= Date() ? Color(hex: model.style.recallColor) : .secondary)
                                    .help("Revisit on \(revisit.formatted(date: .abbreviated, time: .omitted))")
                            }
                        }
                        .tag(note.id)
                    }
                }
            }

            if !model.proposals.isEmpty {
                Section {
                    ForEach(model.proposals) { note in
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles").foregroundStyle(Color(hex: model.style.recallColor)).font(.caption)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(note.title).lineLimit(1)
                                Text("from \(note.source ?? "AI")").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .tag(note.id)
                    }
                } header: {
                    Text("Review · \(model.proposals.count) proposed")
                }
            }

            ForEach(Layer.allCases, id: \.self) { layer in
                let notes = model.notes(in: layer)
                if !notes.isEmpty {
                    Section(Theme.name(layer)) {
                        ForEach(notes) { note in
                            HStack(spacing: 8) {
                                LayerDot(layer: layer, size: 6, hex: model.dotHex(note))
                                Text(note.title).lineLimit(1)
                                if note.isPrivate {
                                    Spacer()
                                    Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            .tag(note.id)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: - Toolbar

private struct PersonaMenu: View {
    @Bindable var model: AppModel

    var body: some View {
        let personas = model.installedPacks.filter { $0.manifest.kind == .persona }
        Menu {
            Button { model.setPersona(nil) } label: {
                Label("Just me (no persona)", systemImage: model.config.activePersona == nil ? "checkmark" : "person")
            }
            if !personas.isEmpty { Divider() }
            ForEach(personas) { pack in
                Button { model.setPersona(pack.id) } label: {
                    Label(pack.manifest.name, systemImage: model.config.activePersona == pack.id ? "checkmark" : "theatermasks")
                }
            }
            Divider()
            Button("Browse personas & packs…") { model.panel = .library; model.showInspector = true }
        } label: {
            Label(model.activePersona?.manifest.name ?? "Persona", systemImage: "theatermasks")
        }
        .help("Switch the AI's personality. The persona joins your core memory.")
    }
}

// MARK: - Overlays

private struct ToastView: View {
    @Bindable var model: AppModel
    let event: ActivityEvent

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Color(hex: model.style.recallColor))
            VStack(alignment: .leading, spacing: 1) {
                Text(event.client).font(.caption.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if event.kind == .remember {
                Button("Review") { model.panel = .note; model.showInspector = true; model.selectedID = model.proposals.last?.id }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color(hex: model.style.recallColor).opacity(0.3)))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var icon: String {
        switch event.kind {
        case .recall: "waveform.path.ecg"
        case .core: "person.crop.circle"
        case .read: "doc.text.magnifyingglass"
        case .remember: "sparkles"
        }
    }

    private var message: String {
        switch event.kind {
        case .recall: "recalled \(event.hits.count) memories · “\(event.query ?? "")”"
        case .core: "loaded your core memory"
        case .read: "read a memory"
        case .remember: "proposed “\(event.query ?? "a memory")”"
        }
    }
}

private struct RecallPanel: View {
    @Bindable var model: AppModel
    private var fire: Color { Color(hex: model.style.recallColor) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "waveform.path.ecg").foregroundStyle(fire)
                Text(model.recallSource ?? "Recall").font(.headline)
                Text("“\(model.lastQuery)”").foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button { model.copyContext() } label: { Image(systemName: "doc.on.clipboard") }
                    .buttonStyle(.borderless)
                    .help("Copy core + these memories as context for ChatGPT, Gemini or any AI")
                Button { model.clearRecall() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Clear (Esc)")
            }
            if model.hits.isEmpty {
                Text("No memories found.").foregroundStyle(.secondary)
            }
            ForEach(Array(model.hits.prefix(8).enumerated()), id: \.element.id) { rank, hit in
                if let note = model.index?.note(hit.id) {
                    Button { model.select(hit.id) } label: {
                        HStack(spacing: 10) {
                            Text("\(rank + 1)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 14)
                            LayerDot(layer: note.layer, size: 6, hex: note.pack?.color)
                            Text(note.title).lineLimit(1)
                            Spacer(minLength: 12)
                            Capsule().fill(fire.opacity(0.25))
                                .frame(width: 60, height: 4)
                                .overlay(alignment: .leading) {
                                    Capsule().fill(fire).frame(width: 60 * hit.score, height: 4)
                                }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .frame(width: 380)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(fire.opacity(0.25)))
    }
}

private struct TimelineBar: View {
    @Bindable var model: AppModel

    var body: some View {
        let start = model.timelineStart.timeIntervalSince1970
        let end = max(start + 1, model.timelineEnd.timeIntervalSince1970)
        HStack(spacing: 14) {
            Button { model.isPlayingTimeline ? model.stopTimeline() : model.playTimeline() } label: {
                Image(systemName: model.isPlayingTimeline ? "pause.fill" : "play.fill").frame(width: 16)
            }
            .buttonStyle(.borderless)
            Text(model.timelineStart.formatted(.dateTime.year())).font(.caption).foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { min(max(model.timelineDate.timeIntervalSince1970, start), end) },
                set: { model.stopTimeline(); model.setTimeline(Date(timeIntervalSince1970: $0)) }
            ), in: start...end)
            Text(model.timelineDate.formatted(.dateTime.month(.abbreviated).year()))
                .font(.callout.monospacedDigit().weight(.medium))
                .frame(width: 80, alignment: .trailing)
            Button { model.timelineActive = false } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: 720)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

private struct LoadingOverlay: View {
    let status: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(status).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Inspector

private struct InspectorContainer: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("Panel", selection: $model.panel) {
                ForEach(AppModel.Panel.allCases) { panel in
                    Image(systemName: panel.icon).help(panel.title).tag(panel)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
            Group {
                switch model.panel {
                case .note: NoteInspector(model: model)
                case .chat: ChatPanel(model: model)
                case .today: TodayPanel(model: model)
                case .tasks: TasksPanel(model: model)
                case .connect: ConnectPanel(model: model)
                case .library: LibraryPanel(model: model)
                case .activity: ActivityPanel(model: model)
                case .health: HealthPanel(model: model)
                case .style: StyleInspector(model: model)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}
