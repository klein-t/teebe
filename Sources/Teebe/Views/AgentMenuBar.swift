import AppKit
import SwiftUI
import TeebeCore

/// The menu bar status item's label: the worktree glyph and, when agents are
/// busy, how many wait for you and how many work, across all projects.
struct AgentMenuBarLabel: View {
    let overview: AgentOverviewModel

    var body: some View {
        let summary = overview.summary
        HStack(spacing: 4) {
            Image(systemName: summary.waiting.isEmpty ? "arrow.triangle.branch" : "exclamationmark.bubble")
            if let title = AgentOverviewModel.title(summary) { Text(title) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AgentOverviewModel.accessibilityLabel(summary))
    }
}

/// The status item's menu: the worktrees waiting for you (with what the agent
/// asks), then those working (with their task). Choosing one brings teebe
/// forward on it.
struct AgentMenuBarMenu: View {
    let overview: AgentOverviewModel
    @Bindable var display: AgentDisplayPreferences
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let summary = overview.summary
        if summary.waiting.isEmpty && summary.working.isEmpty {
            Text("No agents working or waiting")
        }
        if !summary.waiting.isEmpty {
            Section("Waiting for you") {
                ForEach(summary.waiting) { item($0, line: display.showsQuestion ? $0.context?.waitingReason : nil) }
            }
        }
        if !summary.working.isEmpty {
            Section("Working") {
                ForEach(summary.working) { item($0, line: display.showsTask ? task(of: $0) : nil) }
            }
        }
        Divider()
        Button("Open teebe") { AgentOverviewModel.bringMainWindowForward() }
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Hide Menu Bar Icon") { display.showsMenuBarIcon = false }
    }

    private func task(of entry: AgentOverviewModel.Entry) -> String? {
        WorktreeAgentLines(context: entry.context, mark: .working, options: display.options).task
    }

    /// The worktree and its project, then the agent line, shortened for a menu.
    private func item(_ entry: AgentOverviewModel.Entry, line: String?) -> some View {
        Button {
            Task { await overview.open(entry) }
        } label: {
            Text("\(entry.name)  \(entry.repoTitle)")
            if let line, let short = AgentText.line(line, limit: 70) { Text(short) }
        }
    }
}
