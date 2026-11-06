import CortexKit
import SwiftUI

// MARK: - Today

/// A short list of notes that come back on their own, plus every open task in the vault.
struct TodayPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        let items = model.todayItems
        List {
            Section {
                Text("A few notes worth another look: ones you asked to see again, and old ones close to what you're working on now.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if items.isEmpty {
                Section { Text("Nothing to look at again today.").foregroundStyle(.secondary) }
            } else {
                Section("Today · \(items.count)") {
                    ForEach(items) { TodayRow(model: model, item: $0) }
                }
            }
        }
        .listStyle(.inset)
    }
}

private struct TodayRow: View {
    @Bindable var model: AppModel
    let item: ResurfaceItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { model.select(item.note.id) } label: {
                HStack(spacing: 6) {
                    LayerDot(layer: item.note.layer, size: 6, hex: model.dotHex(item.note))
                    Text(item.note.title).lineLimit(1)
                    if item.note.isDecision {
                        Text("Decision").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            Text(reason).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Done") { model.markReviewed(item) }
                    .help("You've looked at it. It stays away for three months.")
                Button("Later") { model.snooze(item) }
                    .help("Bring it back in two weeks.")
                if !item.note.isPrivate {
                    Button("Ask about it") { model.askAbout(item.note) }
                        .help("Start a chat with your agent about this note.")
                }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(.vertical, 2)
    }

    private var reason: String {
        switch item.reason {
        case .revisitDue(let date):
            "You asked to revisit this on \(date.formatted(date: .abbreviated, time: .omitted))"
        case .anniversary(let months):
            months % 12 == 0
                ? "Written \(months / 12) year\(months == 12 ? "" : "s") ago today"
                : "Written \(months) month\(months == 1 ? "" : "s") ago today"
        case .related(let title):
            "Untouched since \(item.note.modified.formatted(date: .abbreviated, time: .omitted)), and close to “\(title)”"
        case .oldest:
            "Untouched since \(item.note.modified.formatted(date: .abbreviated, time: .omitted))"
        }
    }
}

// MARK: - Tasks

struct TasksPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        let tasks = model.index.map { Tasks.open(in: $0.notes) } ?? []
        let dated = tasks.filter { $0.due != nil }
        let undated = Dictionary(grouping: tasks.filter { $0.due == nil }, by: \.noteID)
            .sorted { ($0.value.first?.noteTitle ?? "").localizedStandardCompare($1.value.first?.noteTitle ?? "") == .orderedAscending }
        List {
            Section {
                Text("Every open checkbox in your notes, gathered without any setup. Ticking one here ticks it in its note.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if tasks.isEmpty {
                Section { Text("No open tasks. Write “- [ ] something” in any note and it shows up here.").foregroundStyle(.secondary) }
            }
            if !dated.isEmpty {
                Section("With a date · \(dated.count)") {
                    ForEach(dated) { TaskRow(model: model, task: $0, showNote: true) }
                }
            }
            ForEach(undated, id: \.key) { noteID, group in
                Section {
                    ForEach(group) { TaskRow(model: model, task: $0, showNote: false) }
                } header: {
                    Button { model.select(noteID) } label: { Text("\(group[0].noteTitle) · \(group.count)").lineLimit(1) }
                        .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.inset)
    }
}

private struct TaskRow: View {
    @Bindable var model: AppModel
    let task: VaultTask

    let showNote: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button { model.complete(task) } label: { Image(systemName: "circle") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Mark as done")
            VStack(alignment: .leading, spacing: 2) {
                MarkdownBody(text: task.text)
                if showNote || task.due != nil {
                    HStack(spacing: 6) {
                        if let due = task.due {
                            Text(due.formatted(date: .abbreviated, time: .omitted))
                                .foregroundStyle(due < Calendar.current.startOfDay(for: Date()) ? Color(hex: model.style.contextColor) : .secondary)
                        }
                        if showNote { Text(task.noteTitle).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    .font(.caption)
                }
            }
        }
    }
}

// MARK: - Usage (in the health panel)

/// Which notes AI tools actually use.
struct UsageSection: View {
    @Bindable var model: AppModel
    let report: UsageReport

    var body: some View {
        Section {
            if report.since == nil {
                Text("No AI tool has searched this memory in the last 90 days.").foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("\(report.used.count) of \(report.eligible) notes used")
                    Spacer()
                    Text("\(report.usedPercent)%").monospacedDigit().foregroundStyle(.secondary)
                }
                // Keyed by position: the same note can also be listed further down this panel's list.
                ForEach(Array(report.used.prefix(5).enumerated()), id: \.offset) { _, item in
                    Button { model.select(item.note.id) } label: {
                        HStack(spacing: 6) {
                            LayerDot(layer: item.note.layer, size: 6, hex: model.dotHex(item.note))
                            Text(item.note.title).lineLimit(1)
                            Spacer()
                            Text("\(item.count)×").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 14) {
                    if !report.used.isEmpty { Button("Show used on graph") { model.showUsage(report.used.map(\.note.id), label: "Most used") } }
                    if !report.unused.isEmpty { Button("Show \(report.unused.count) never used") { model.showUsage(report.unused.map(\.id), label: "Never used") } }
                }
                .buttonStyle(.link)
                .font(.caption)
                // In a row, not the section footer: a list cuts a long footer off.
                Text("Last 90 days\(report.since.map { ", counted since \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""). Core notes are always loaded, so they don't count. “Never used” skips notes younger than a month.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("What your AI actually uses")
        }
    }
}
