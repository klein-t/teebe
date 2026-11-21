import Foundation
import Observation
import TeebeCore

/// Which prompt the task line under a branch name shows.
enum AgentTaskSource: String, CaseIterable, Identifiable {
    case first, latest
    var id: String { rawValue }
    var title: String {
        switch self {
        case .first: "First prompt"
        case .latest: "Latest prompt"
        }
    }
}

/// What the worktree rows and hover cards show about agents.
struct AgentDisplayOptions: Equatable {
    var showsQuestion = true
    var showsTask = true
    var taskSource: AgentTaskSource = .first
}

/// Shared wording for the WORKTREES menu, the menu bar menu and Settings.
enum AgentDisplayWording {
    static let questionTitle = "Show what agents ask"
    static let questionHelp = "While an agent waits, show its question or request on the row and in its card. "
        + "Without one, the end of its last message."
    static let taskTitle = "Show task under branch"
    static let taskHelp = "Show the prompt the agent was given under the branch name."
    static let taskSourceTitle = "Task from"
    static let menuBarTitle = "Show in menu bar"
    static let menuBarHelp = "A menu bar icon counts and lists the agents waiting for you and working, in all your projects. "
        + "Choose below which of them it shows."
    static let waitingAgentsTitle = "Waiting agents"
    static let workingAgentsTitle = "Working agents"
    static let animateTitle = "Animate icons"
    static let dockTitle = "Show Dock icon"
    static let dockHelp = "Hide the Dock icon and use teebe from the menu bar. Needs the menu bar icon; "
        + "hiding the menu bar icon brings the Dock icon back."
    static let sectionTitle = "Agent details"
    static let privacyNote = "Read from Claude Code and Codex logs on this Mac. Shown here only, never sent anywhere."
}

/// The global agent display choices. Defaults are all on, task from the first prompt.
@MainActor
@Observable
final class AgentDisplayPreferences {
    var showsQuestion: Bool { didSet { if showsQuestion != oldValue { onChange() } } }
    var showsTask: Bool { didSet { if showsTask != oldValue { onChange() } } }
    var taskSource: AgentTaskSource { didSet { if taskSource != oldValue { onChange() } } }
    /// The menu bar item and the Dock icon, kept so that one of them always shows.
    private(set) var presence: AppPresence
    var showsMenuBarIcon: Bool {
        get { presence.showsMenuBarIcon }
        set { updatePresence { $0.setMenuBarIcon(newValue) } }
    }
    var showsDockIcon: Bool {
        get { presence.showsDockIcon }
        set { updatePresence { $0.setDockIcon(newValue) } }
    }
    var showsWaitingAgents: Bool { didSet { if showsWaitingAgents != oldValue { onChange() } } }
    var showsWorkingAgents: Bool { didSet { if showsWorkingAgents != oldValue { onChange() } } }
    var animatesMenuBarIcons: Bool { didSet { if animatesMenuBarIcons != oldValue { onChange() } } }
    @ObservationIgnored var onChange: () -> Void = {}
    /// Called with whether the Dock icon should show, whenever that changes.
    @ObservationIgnored var onDockIconChange: (Bool) -> Void = { _ in }

    private func updatePresence(_ change: (inout AppPresence) -> Void) {
        var updated = presence
        change(&updated)
        guard updated != presence else { return }
        let dockChanged = updated.showsDockIcon != presence.showsDockIcon
        presence = updated
        onChange()
        if dockChanged { onDockIconChange(updated.showsDockIcon) }
    }

    init(state: AppState) {
        showsQuestion = state.agentShowQuestion ?? true
        showsTask = state.agentShowTask ?? true
        taskSource = AgentTaskSource(rawValue: state.agentTaskSource ?? "") ?? .first
        presence = AppPresence(showsMenuBarIcon: state.agentMenuBarIcon ?? true,
                               showsDockIcon: state.showDockIcon ?? true)
        showsWaitingAgents = state.agentMenuBarWaiting ?? true
        showsWorkingAgents = state.agentMenuBarWorking ?? true
        animatesMenuBarIcons = state.agentMenuBarAnimate ?? true
    }

    var options: AgentDisplayOptions {
        AgentDisplayOptions(showsQuestion: showsQuestion, showsTask: showsTask, taskSource: taskSource)
    }

    func write(to state: inout AppState) {
        state.agentShowQuestion = showsQuestion
        state.agentShowTask = showsTask
        state.agentTaskSource = taskSource.rawValue
        state.agentMenuBarIcon = showsMenuBarIcon
        state.agentMenuBarWaiting = showsWaitingAgents
        state.agentMenuBarWorking = showsWorkingAgents
        state.agentMenuBarAnimate = animatesMenuBarIcons
        state.showDockIcon = showsDockIcon
    }
}

/// The extra lines a worktree row shows under its branch name: the task its
/// agent was given, and what the agent asks while it waits. Pure.
struct WorktreeAgentLines: Equatable {
    /// The prompt the session was given; nil without a working or waiting session.
    let task: String?
    /// What the waiting agent asks; nil unless the row shows the waiting mark.
    let question: String?

    var count: Int { (task == nil ? 0 : 1) + (question == nil ? 0 : 1) }

    static let none = WorktreeAgentLines(task: nil, question: nil)

    init(task: String?, question: String?) {
        self.task = task
        self.question = question
    }

    init(context: AgentContext?, mark: WorktreeMark, options: AgentDisplayOptions) {
        guard let context, context.state != .idle else {
            self.init(task: nil, question: nil)
            return
        }
        let task: String?
        switch options.taskSource {
        // A prompt outside the read window is not known; the other one is still the session's.
        case .first: task = context.firstPrompt ?? context.latestPrompt
        case .latest: task = context.latestPrompt ?? context.firstPrompt
        }
        let waiting = mark == .waiting && context.state == .needsAttention
        self.init(task: options.showsTask ? task : nil,
                  question: options.showsQuestion && waiting ? context.waitingReason : nil)
    }
}
