import CortexKit
import SwiftUI

// MARK: - Packs (library)

struct LibraryPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        let installedIDs = Set(model.installedPacks.map(\.id))
        let available = model.starterPacks.filter { !installedIDs.contains($0.id) }
        List {
            Section {
                Text("Packs are collections of expertise and personalities that plug into your memory. Knowledge packs connect to your own notes; a persona changes how every AI tool works with you.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section("Installed") {
                if model.installedPacks.isEmpty {
                    Text("Nothing installed yet — try a starter pack below.").foregroundStyle(.secondary)
                }
                ForEach(model.installedPacks) { pack in
                    InstalledPackRow(model: model, pack: pack)
                }
            }

            if !available.isEmpty {
                Section("Starter packs") {
                    ForEach(available) { pack in
                        PackRow(pack: pack) {
                            Button("Install") { model.install(pack.url) }
                                .controlSize(.small)
                        }
                    }
                }
            }

            Section("Share") {
                Button { model.importPack() } label: { Label("Import pack…", systemImage: "square.and.arrow.down") }
                Button { model.exportCore() } label: { Label("Export my core as a persona pack…", systemImage: "square.and.arrow.up") }
                Text("Your exported core (writing style, preferences) can be shared with your team or loaded into another Cortex. Private notes are never included.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
    }
}

private struct InstalledPackRow: View {
    @Bindable var model: AppModel
    let pack: InstalledPack

    var body: some View {
        PackRow(pack: pack) {
            if pack.manifest.kind == .persona {
                let active = model.config.activePersona == pack.id
                Button(active ? "Active" : "Use") { model.setPersona(active ? nil : pack.id) }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .tint(active ? Color(hex: pack.manifest.color) : nil)
            } else {
                Toggle("", isOn: Binding(
                    get: { model.config.enabledPacks.contains(pack.id) },
                    set: { model.setPack(pack.id, enabled: $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            }
        }
        .contextMenu {
            Button("Remove pack", role: .destructive) { model.removePack(pack.id) }
        }
    }
}

private struct PackRow<Accessory: View>: View {
    let pack: InstalledPack
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(Color(hex: pack.manifest.color)).frame(width: 26, height: 26)
                Image(systemName: pack.manifest.kind == .persona ? "theatermasks.fill" : "books.vertical.fill")
                    .font(.system(size: 11)).foregroundStyle(.black.opacity(0.65))
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(pack.manifest.name).font(.callout.weight(.semibold))
                    Text(pack.manifest.kind == .persona ? "PERSONA" : "\(pack.noteCount) NOTES")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text(pack.manifest.description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("by \(pack.manifest.author) · v\(pack.manifest.version)").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            accessory
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Activity (Recall Theater)

struct ActivityPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        List {
            Section {
                if model.activity.isEmpty {
                    Text("Nothing yet. Connect an AI tool below — every time it recalls a memory, it lights up in the network and appears here.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(model.activity.prefix(80)) { event in
                    Button { model.replay(event) } label: { ActivityRow(model: model, event: event) }
                        .buttonStyle(.plain)
                }
            } header: {
                Text("What your AI tools remembered")
            }

            Section {
                Button { model.panel = .connect } label: {
                    Label(model.connection.any ? "Manage connected AI apps…" : "Connect Claude, Cursor and other AI apps…", systemImage: "link")
                }
            }
        }
        .listStyle(.inset)
    }
}

private struct ActivityRow: View {
    @Bindable var model: AppModel
    let event: ActivityEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Color(hex: model.style.recallColor))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(event.client).font(.callout.weight(.semibold))
                    Spacer()
                    Text(event.time, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.tertiary)
                }
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if !event.hits.isEmpty {
                    Text(event.hits.prefix(4).compactMap { model.index?.note($0.id)?.title }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var icon: String {
        switch event.kind {
        case .recall: "waveform.path.ecg"
        case .core: "person.crop.circle"
        case .read: "doc.text.magnifyingglass"
        case .remember: "sparkles"
        }
    }

    private var summary: String {
        switch event.kind {
        case .recall: "Recalled \(event.hits.count) for “\(event.query ?? "")”"
        case .core: "Loaded core memory (\(event.hits.count) notes)"
        case .read: "Read “\(model.index?.note(event.note ?? "")?.title ?? event.note ?? "")”"
        case .remember: "Proposed “\(event.query ?? "")”"
        }
    }
}

// MARK: - Health

struct HealthPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        if let health = model.index?.health() {
            List {
                Section {
                    HStack(spacing: 16) {
                        ZStack {
                            Circle().stroke(.white.opacity(0.08), lineWidth: 6)
                            Circle().trim(from: 0, to: Double(health.score) / 100)
                                .stroke(scoreColor(health.score), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text("\(health.score)").font(.title2.weight(.semibold).monospacedDigit())
                        }
                        .frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Memory health").font(.headline)
                            Text("Fewer duplicates, dead links and forgotten projects mean better answers from every AI tool.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }

                issueSection("Waiting for review", "AI-proposed memories", notes: health.proposals)
                if !health.duplicates.isEmpty {
                    Section("Possible duplicates") {
                        ForEach(health.duplicates, id: \.0.id) { a, b, sim in
                            HStack {
                                noteLink(a)
                                Image(systemName: "arrow.left.and.right").font(.caption2).foregroundStyle(.tertiary)
                                noteLink(b)
                                Spacer()
                                Text(String(format: "%.0f%%", sim * 100)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                if !health.brokenLinks.isEmpty {
                    Section("Links to nowhere") {
                        ForEach(Array(health.brokenLinks.enumerated()), id: \.offset) { _, item in
                            HStack {
                                noteLink(item.0)
                                Spacer()
                                Text("[[\(item.1)]]").font(.caption.monospaced()).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                issueSection("Not touched in 90 days", "Active projects or areas that may be outdated", notes: health.stale)
                issueSection("Isolated", "Memories with no connection at all", notes: health.isolated)
            }
            .listStyle(.inset)
        } else {
            ContentUnavailableView("Loading", systemImage: "heart.text.square")
        }
    }

    @ViewBuilder
    private func issueSection(_ title: String, _ caption: String, notes: [Note]) -> some View {
        if !notes.isEmpty {
            Section {
                ForEach(notes) { noteLink($0) }
            } header: {
                Text("\(title) · \(notes.count)")
            } footer: {
                Text(caption).font(.caption2)
            }
        }
    }

    private func noteLink(_ note: Note) -> some View {
        Button { model.select(note.id) } label: {
            HStack(spacing: 6) {
                LayerDot(layer: note.layer, size: 6, hex: note.pack?.color)
                Text(note.title).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    private func scoreColor(_ score: Int) -> Color {
        score >= 80 ? Color(hex: "#6cc3a0") : score >= 60 ? Color(hex: model.style.recallColor) : Color(hex: model.style.contextColor)
    }
}
