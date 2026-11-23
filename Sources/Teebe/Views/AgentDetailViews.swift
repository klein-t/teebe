import SwiftUI
import TeebeCore

/// The agent lines under a worktree's branch name: the task, then what the
/// waiting agent asks. One truncated line each; hovering the row slides any that
/// are cut off, so they can be read in full.
struct WorktreeAgentLinesView: View {
    let lines: WorktreeAgentLines
    let isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let task = lines.task {
            line(task, color: isSelected ? Color.white.opacity(0.8) : Palette.secondaryText)
                .accessibilityLabel("Task: \(task)")
        }
        if let question = lines.question {
            line(question, color: questionColor)
                .accessibilityLabel("Agent asks: \(question)")
        }
    }

    private func line(_ text: String, color: Color) -> some View {
        HoverSlidingLine(text: text, selection: isSelected)
            .font(Typography.secondary)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: WorktreeListPresentation.agentLineHeight, alignment: .top)
            .padding(.leading, 2)
    }

    /// The waiting orb's ink, so the question reads as part of that mark.
    private var questionColor: Color {
        if isSelected { return .white }
        return colorScheme == .dark ? Color(red: 0xFF / 255, green: 0xC0 / 255, blue: 0x70 / 255)
            : Color(red: 0xB0 / 255, green: 0x58 / 255, blue: 0x00 / 255)
    }
}

/// The agent options of the WORKTREES "···" menu. Global, like Settings.
struct AgentRowOptionsMenuSection: View {
    @Bindable var display: AgentDisplayPreferences

    var body: some View {
        Section("Agents, all projects") {
            Toggle(AgentDisplayWording.questionTitle, isOn: $display.showsQuestion)
            Toggle(AgentDisplayWording.taskTitle, isOn: $display.showsTask)
            Picker(AgentDisplayWording.taskSourceTitle, selection: $display.taskSource) {
                ForEach(AgentTaskSource.allCases) { Text($0.title).tag($0) }
            }
            .disabled(!display.showsTask)
            Toggle(AgentDisplayWording.menuBarTitle, isOn: $display.showsMenuBarIcon)
            MenuBarCountToggles(display: display, indent: "    ")
        }
    }
}

/// What the menu bar item shows and lists, under "Show in menu bar" and off while it is.
/// `indent` sets them under it in a menu, where rows can't be padded.
struct MenuBarCountToggles: View {
    @Bindable var display: AgentDisplayPreferences
    var indent = ""

    var body: some View {
        Toggle(indent + AgentDisplayWording.waitingAgentsTitle, isOn: $display.showsWaitingAgents)
            .disabled(!display.showsMenuBarIcon)
        Toggle(indent + AgentDisplayWording.workingAgentsTitle, isOn: $display.showsWorkingAgents)
            .disabled(!display.showsMenuBarIcon)
        Toggle(indent + AgentDisplayWording.animateTitle, isOn: $display.animatesMenuBarIcons)
            .disabled(!display.showsMenuBarIcon)
    }
}

/// The same options in Settings.
struct AgentDisplaySettingsSection: View {
    @Bindable var display: AgentDisplayPreferences

    var body: some View {
        Section {
            Toggle(isOn: $display.showsQuestion) { labeled(AgentDisplayWording.questionTitle, AgentDisplayWording.questionHelp) }
            Toggle(isOn: $display.showsTask) { labeled(AgentDisplayWording.taskTitle, AgentDisplayWording.taskHelp) }
            Picker(AgentDisplayWording.taskSourceTitle, selection: $display.taskSource) {
                ForEach(AgentTaskSource.allCases) { Text($0.title).tag($0) }
            }
            .disabled(!display.showsTask)
            Toggle(isOn: $display.showsMenuBarIcon) { labeled(AgentDisplayWording.menuBarTitle, AgentDisplayWording.menuBarHelp) }
            MenuBarCountToggles(display: display).padding(.leading, 16)
            Toggle(isOn: $display.showsDockIcon) { labeled(AgentDisplayWording.dockTitle, AgentDisplayWording.dockHelp) }
                // Reads as on while the menu bar icon is off: the Dock icon is the only way in.
                .disabled(!display.presence.canHideDockIcon)
        } header: { Text(AgentDisplayWording.sectionTitle) } footer: {
            Text(AgentDisplayWording.privacyNote)
        }
    }

    private func labeled(_ title: String, _ help: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
            HelpInfo(title: title, explanation: help)
        }
    }
}
