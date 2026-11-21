import Foundation
import Testing
@testable import Teebe
@testable import TeebeCore

@Suite("Agent menu bar counts")
@MainActor
struct AgentOverviewTests {
    func entry(_ name: String, repo: String, _ state: AgentActivityState) -> AgentOverviewModel.Entry {
        AgentOverviewModel.Entry(repoPath: "/r/\(repo)", repoTitle: repo, worktreePath: "/r/\(repo)/\(name)", name: name,
                                 state: state, context: nil)
    }

    @Test("counts waiting and working across repositories; idle counts for nothing")
    func counts() {
        let summary = AgentOverviewModel.summarize([
            entry("feat/b", repo: "web", .needsAttention), entry("main", repo: "web", .idle),
            entry("fix/a", repo: "api", .working), entry("feat/a", repo: "web", .needsAttention),
            entry("feat/z", repo: "api", .needsAttention)
        ])
        #expect(summary.waiting.map(\.name) == ["feat/z", "feat/a", "feat/b"])
        #expect(summary.working.map(\.name) == ["fix/a"])
        #expect(AgentOverviewModel.title(summary) == "3 waiting · 1 working")
        #expect(AgentOverviewModel.accessibilityLabel(summary) == "Teebe: 3 waiting for you, 1 working")
    }

    @Test("the title leaves out zero parts and is empty when nothing is going on")
    func titles() {
        #expect(AgentOverviewModel.title(.init()) == nil)
        #expect(AgentOverviewModel.title(AgentOverviewModel.summarize([entry("a", repo: "x", .working)])) == "1 working")
        #expect(AgentOverviewModel.title(AgentOverviewModel.summarize([entry("a", repo: "x", .needsAttention)])) == "1 waiting")
    }
}

@Suite("Worktree agent lines")
struct WorktreeAgentLinesTests {
    let waiting = AgentContext(state: .needsAttention, firstPrompt: "First", latestPrompt: "Latest", waitingReason: "Proceed?")

    @Test("a waiting row shows the task and the question; options turn each off")
    func options() {
        let all = WorktreeAgentLines(context: waiting, mark: .waiting, options: AgentDisplayOptions())
        #expect(all == WorktreeAgentLines(task: "First", question: "Proceed?"))
        #expect(all.count == 2)
        let latest = AgentDisplayOptions(showsQuestion: false, showsTask: true, taskSource: .latest)
        #expect(WorktreeAgentLines(context: waiting, mark: .waiting, options: latest) == WorktreeAgentLines(task: "Latest", question: nil))
        let none = AgentDisplayOptions(showsQuestion: false, showsTask: false)
        #expect(WorktreeAgentLines(context: waiting, mark: .waiting, options: none) == .none)
    }

    @Test("only the waiting mark shows a question; a missing prompt falls back to the other one")
    func fallbacks() {
        #expect(WorktreeAgentLines(context: waiting, mark: .working, options: AgentDisplayOptions()).question == nil)
        let onlyLatest = AgentContext(state: .working, latestPrompt: "Latest")
        #expect(WorktreeAgentLines(context: onlyLatest, mark: .working, options: AgentDisplayOptions()).task == "Latest")
        #expect(WorktreeAgentLines(context: nil, mark: .waiting, options: AgentDisplayOptions()) == .none)
    }

    @Test("the waiting card says what the agent asks, or the generic sentence without it")
    func card() {
        let worktree = Worktree(path: "/feature", branch: "feature", head: "abc")
        var info = SelectorModel.WorktreeInfo()
        info.agentState = .needsAttention
        info.agentContext = waiting
        let status = WorktreeStatus(worktree: worktree, merge: nil, info: info, targetNames: [], isChecking: false)
        #expect(status.card.title == "Waiting for you")
        #expect(status.card.subtitle == "Proceed?")
        let off = WorktreeStatus(worktree: worktree, merge: nil, info: info, targetNames: [], isChecking: false,
                                 agentDisplay: AgentDisplayOptions(showsQuestion: false))
        #expect(off.card.subtitle == "An agent is waiting for your input.")
        info.agentContext = nil
        let unknown = WorktreeStatus(worktree: worktree, merge: nil, info: info, targetNames: [], isChecking: false)
        #expect(unknown.card.subtitle == "An agent is waiting for your input.")
    }

    @Test("the list grows by each agent line and one bottom inset; one-line rows keep their height")
    func listHeight() {
        let worktree = Worktree(path: "/feature", branch: "feature", head: "abc")
        var info = SelectorModel.WorktreeInfo()
        info.agentState = .needsAttention
        info.agentContext = waiting
        let status = WorktreeStatus(worktree: worktree, merge: nil, info: info, targetNames: [], isChecking: false)
        let plain = WorktreeListPresentation(worktrees: [worktree], statuses: [:], grouped: false, collapsed: [], hasRepository: true)
        let lined = WorktreeListPresentation(worktrees: [worktree], statuses: [worktree.path: status], grouped: false,
                                             collapsed: [], hasRepository: true)
        #expect(lined.naturalHeight - plain.naturalHeight
                == 2 * WorktreeListPresentation.agentLineHeight + WorktreeListPresentation.agentLinesBottomInset)
        #expect(WorktreeListPresentation.rowHeight(agentLines: 0) == WorktreeListPresentation.rowHeight)
        #expect(WorktreeListPresentation.rowHeight(agentLines: 2) == WorktreeListPresentation.rowHeight + 36)
    }
}
