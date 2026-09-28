import Foundation
import Testing
import TeebeCore
@testable import Teebe

@Suite("Worktree status marks and cards")
struct WorktreeStatusTests {
    private let feature = Worktree(path: "/feature", branch: "feature", head: "abc")
    private static let catalog = CleanupTargets.parse(
        "refs/remotes/origin/dev\u{0}d\u{0}\u{0}\nrefs/remotes/origin/main\u{0}m\u{0}\u{0}\n")
    private let dev = catalog.branches[0]
    private let main = catalog.branches[1]

    private func entry(_ worktree: Worktree? = nil, merged into: [CleanupBranch] = [],
                       squashed: Bool = false, _ tweak: (inout CleanupEntry) -> Void = { _ in }) -> CleanupEntry {
        var entry = CleanupEntry(worktree: worktree ?? feature)
        entry.mergeStatus = into.isEmpty ? .notConfirmed : .merged
        entry.mergedTargets = into
        entry.hasEquivalentContent = squashed
        tweak(&entry)
        return entry
    }

    private func status(_ entry: CleanupEntry?, worktree: Worktree? = nil, count: Int = 0,
                        info: SelectorModel.WorktreeInfo = .init(), isChecking: Bool = false) -> WorktreeStatus {
        WorktreeStatus(worktree: worktree ?? entry?.worktree ?? feature,
                       merge: entry.map { WorktreeMergeEntry(entry: $0, localChangeCount: count) },
                       info: info, targetNames: ["main", "dev"], isChecking: isChecking)
    }

    private func facts(_ status: WorktreeStatus) -> [String] { status.card.facts.map { $0.text } }

    @Test("one mark per row, highest precedence wins")
    func precedence() {
        let merged = entry(merged: [dev])
        #expect(status(merged).mark == .merged)
        #expect(status(entry()).mark == .notMerged)
        #expect(status(nil, isChecking: true).mark == .notMerged)
        #expect(status(entry(merged: [dev]) { $0.isBroken = true }).mark == .brokenLink)
        #expect(status(merged, count: 2).mark == .uncommitted)
        #expect(status(entry(merged: [dev]) { $0.hasLocalChanges = true }).mark == .uncommitted)
        #expect(status(merged, count: 2, info: .init(agentState: .needsAttention)).mark == .waiting)
        #expect(status(merged, count: 2, info: .init(agentState: .working)).mark == .working)
        // Files changing with no agent reads as working too…
        #expect(status(merged, info: .init(isLive: true)).mark == .working)
        // …but a waiting agent outranks stray file activity.
        #expect(status(merged, info: .init(isLive: true, agentState: .needsAttention)).mark == .waiting)
        // Git could be hiding local work: no ✓.
        #expect(status(entry(merged: [dev]) { $0.hasUncheckedFiles = true }).mark == .notMerged)
        #expect(status(entry(merged: [dev]) { $0.hasSubmodules = true }).mark == .notMerged)
        // Ignored files don't block the ✓.
        #expect(status(entry(merged: [dev]) { $0.hasIgnoredFiles = true }).mark == .merged)
    }

    @Test("a branch with no commits of its own gets the ring and says so, never the trash")
    func freshBranch() {
        let fresh = status(entry { $0.hasNoCommits = true })
        #expect(fresh.mark == .notMerged)
        #expect(fresh.group == .notMerged)
        #expect(!fresh.showsTrash)
        #expect(fresh.card.title == "Not merged")
        #expect(fresh.card.subtitle == "No commits yet.")
        #expect(facts(fresh) == ["No uncommitted changes", "No commits yet", "Not on remote"])
        // Its first untracked file makes it uncommitted work, like any other row.
        #expect(status(entry { $0.hasNoCommits = true }, count: 1).mark == .uncommitted)
        let prompt = WorktreeRemovalPrompt(worktree: feature, status: fresh,
                                           merge: WorktreeMergeEntry(entry: entry { $0.hasNoCommits = true }))
        #expect(prompt.facts.first == WorktreeCardFact(icon: .merge, text: "No commits yet", tone: .muted))
        #expect(prompt.item == WorktreeRemovalItem(name: "feature", path: "/feature", isMerged: false))
        let safe = status(entry(merged: [dev]))
        #expect(WorktreeRemovalPrompt(worktree: feature, status: safe, merge: WorktreeMergeEntry(entry: entry(merged: [dev])))
            .item == WorktreeRemovalItem(name: "feature", path: "/feature", isMerged: true))
        #expect(!prompt.offersBranchDeletion)
    }

    @Test("a merge target's own checkout has no merge mark but still shows activity and edits")
    func targetCheckout() {
        let devTree = Worktree(path: "/dev", branch: "dev")
        let target = entry(devTree, merged: [dev]) { $0.isTarget = true }
        #expect(status(target).mark == .none)
        #expect(status(target).isPinned)
        #expect(!status(target).showsTrash)
        #expect(status(target, count: 1).mark == .uncommitted)
        // A target can't be removed, so its edits are not a removal blocker.
        #expect(status(target, count: 1).card.subtitle == "Work here isn’t committed yet.")
        #expect(status(target, info: .init(agentState: .working)).mark == .working)
        #expect(facts(status(target, count: 1)) == ["1 uncommitted change", "Merge target", "Not on remote"])
        #expect(status(target).card.title == "Base branch")
        #expect(status(target).card.subtitle == "Other worktrees are compared to it.")
        #expect(facts(status(target)) == ["No uncommitted changes", "Merge target", "Not on remote"])
    }

    @Test("the trash shows on removable ✓ rows only, never on a broken link")
    func trash() {
        let merged = entry(merged: [dev])
        #expect(status(merged).trashAction == .remove(merged))
        #expect(!status(entry(merged: [dev]) { $0.isBroken = true }).showsTrash)
        #expect(!status(entry()).showsTrash)
        #expect(!status(merged, info: .init(agentState: .working)).showsTrash)
        let locked = Worktree(path: "/locked", branch: "locked", isLocked: true)
        let lockedEntry = entry(locked, merged: [dev]) { $0.problem = "Locked worktree" }
        #expect(status(lockedEntry).mark == .notMerged)
        #expect(!status(lockedEntry).showsTrash)
        let primary = Worktree(path: "/repo", branch: "feature", isPrimary: true)
        #expect(!status(entry(primary, merged: [dev])).showsTrash)
        #expect(status(entry(primary, merged: [dev])).isPinned)
    }

    @Test("only a row that would otherwise be safe to delete says to commit before removing")
    func uncommittedSubtitle() {
        #expect(status(entry(merged: [dev]), count: 2).card.subtitle == "Commit or discard them before removing.")
        let locked = Worktree(path: "/locked", branch: "locked", isLocked: true)
        #expect(status(entry(locked, merged: [dev]) { $0.problem = "Locked worktree" }, count: 2).card.subtitle
                == "Work here isn’t committed yet.")
        let primary = Worktree(path: "/repo", branch: "feature", isPrimary: true)
        #expect(status(entry(primary, merged: [dev]), count: 2).card.subtitle == "Work here isn’t committed yet.")
        #expect(status(entry(), count: 2).card.subtitle == "Work here isn’t committed yet.")
    }

    @Test("grouped rows leave the git-state mark to their group heading; orbs and pinned rows keep theirs")
    func groupedRowMark() {
        let merged = status(entry(merged: [dev]))
        #expect(merged.rowMark(grouped: false) == .merged)
        #expect(merged.rowMark(grouped: true) == .none)
        #expect(status(entry(), count: 2).rowMark(grouped: true) == .none)
        #expect(status(entry()).rowMark(grouped: true) == .none)
        // No heading says "broken link", so that row keeps its mark and card.
        #expect(status(entry { $0.isBroken = true }).rowMark(grouped: true) == .brokenLink)
        #expect(status(entry(), info: .init(agentState: .working)).rowMark(grouped: true) == .working)
        #expect(status(entry(), info: .init(agentState: .needsAttention)).rowMark(grouped: true) == .waiting)
        let devTree = Worktree(path: "/dev", branch: "dev")
        let target = entry(devTree, merged: [dev]) { $0.isTarget = true }
        #expect(status(target, count: 1).rowMark(grouped: true) == .uncommitted)
        let primary = Worktree(path: "/repo", branch: "feature", isPrimary: true)
        #expect(status(entry(primary, merged: [dev])).rowMark(grouped: true) == .notMerged)
    }

    @Test("the hover card opens from the mark, so a row without a visible mark has none")
    func hoverCardNeedsAMark() {
        #expect(status(entry(merged: [dev])).hasHoverCard(grouped: false))
        #expect(!status(entry(merged: [dev])).hasHoverCard(grouped: true))
        #expect(status(entry(), info: .init(agentState: .working)).hasHoverCard(grouped: true))
        let devTree = Worktree(path: "/dev", branch: "dev")
        let target = entry(devTree, merged: [dev]) { $0.isTarget = true }
        #expect(!status(target).hasHoverCard(grouped: false))
        #expect(status(target, count: 1).hasHoverCard(grouped: true))
    }

    @Test("every card has a fixed state title, one short sentence, and the same three facts")
    func cards() {
        let merged = status(entry(merged: [main, dev]), info: .init(remote: .sameBranch(remote: "origin", ahead: 0, behind: 0)))
        #expect(merged.card.title == "Safe to delete")
        #expect(merged.card.subtitle == "All its work is merged. You can remove it.")
        #expect(merged.card.facts == [
            WorktreeCardFact(icon: .pencil, text: "No uncommitted changes", tone: .muted),
            WorktreeCardFact(icon: .merge, text: "Merged into main and dev", tone: .positive),
            WorktreeCardFact(icon: .cloud, text: "Up to date with origin", tone: .muted)
        ])

        let squashed = status(entry(merged: [dev], squashed: true), info: .init(remote: .remoteDeleted))
        #expect(facts(squashed) == ["No uncommitted changes", "Merged into dev (squashed)", "Remote branch deleted"])
        #expect(squashed.card.facts.map(\.icon) == [.pencil, .merge, .cloud])

        let dirty = status(entry(merged: [dev], squashed: true), count: 8)
        #expect(dirty.card.title == "Uncommitted changes")
        #expect(dirty.card.subtitle == "Commit or discard them before removing.")
        #expect(dirty.card.facts.first == WorktreeCardFact(icon: .pencil, text: "8 uncommitted changes", tone: .warn))
        #expect(facts(dirty) == ["8 uncommitted changes", "Merged into dev (squashed)", "Not on remote"])

        let unmerged = status(entry(), count: 1, info: .init(remote: .sameBranch(remote: "origin", ahead: 4, behind: 0)))
        #expect(unmerged.card.title == "Uncommitted changes")
        #expect(unmerged.card.subtitle == "Work here isn’t committed yet.")
        #expect(unmerged.card.facts == [
            WorktreeCardFact(icon: .pencil, text: "1 uncommitted change", tone: .warn),
            WorktreeCardFact(icon: .merge, text: "Not in main or dev yet", tone: .muted),
            WorktreeCardFact(icon: .cloud, text: "4 to push", tone: .normal)
        ])

        let working = status(entry(), count: 3, info: .init(agentState: .working,
                                                            remote: .sameBranch(remote: "origin", ahead: 2, behind: 3)))
        #expect(working.card.title == "Agent working")
        #expect(working.card.subtitle == "An agent is working in this worktree.")
        #expect(facts(working) == ["3 uncommitted changes", "Not in main or dev yet", "2 to push · 3 to pull"])
        // Files changing or a command running with no agent share the working mark;
        // the sentence says what is happening.
        #expect(status(entry(), info: .init(isLive: true)).card.subtitle == "Files are changing or a command is running here.")

        let waiting = status(entry(), info: .init(agentState: .needsAttention, remote: .sameBranch(remote: "origin", ahead: 0, behind: 2)))
        #expect(waiting.card.title == "Waiting for you")
        #expect(waiting.card.subtitle == "An agent is waiting for your input.")
        #expect(waiting.card.facts.last == WorktreeCardFact(icon: .cloud, text: "2 to pull", tone: .muted))

        let ring = status(entry())
        #expect(ring.card.title == "Not merged")
        #expect(ring.card.subtitle == "Its commits aren’t merged yet.")
        #expect(facts(ring) == ["No uncommitted changes", "Not in main or dev yet", "Not on remote"])

        let unknown = status(entry { $0.mergeStatus = .unknown; $0.problem = "Could not inspect this worktree" })
        #expect(unknown.card.title == "Couldn’t check")
        #expect(unknown.card.subtitle == "Git couldn’t compare this branch.")
        #expect(facts(unknown)[1] == "Couldn’t check merge status")

        let unlinked = status(entry {
            $0.isBroken = true
            $0.problem = "Broken worktree: its .git link is missing. Remaining files were not changed."
        })
        #expect(unlinked.card.title == "Broken link")
        #expect(unlinked.card.subtitle == "The folder’s .git link is missing, so Teebe leaves its files alone.")
        #expect(unlinked.card.facts.isEmpty)
        #expect(unlinked.group == .notMerged)
    }

    @Test("a row with no result yet reads as checking, then as unknown")
    func noResultYet() {
        let checking = status(nil, isChecking: true)
        #expect(checking.card.title == "Checking…")
        #expect(checking.card.subtitle == "Looking for this branch in main or dev.")
        #expect(facts(checking) == ["No uncommitted changes", "Checking merge status…", "Not on remote"])
        #expect(status(nil).card.title == "Couldn’t check")
        #expect(facts(status(nil))[1] == "Couldn’t check merge status")
    }

    @Test("a result known to be stale shows checking, never Safe to delete, and the row keeps its group")
    func staleResult() {
        let merged = entry(merged: [dev])
        let rechecking = WorktreeStatus(worktree: feature, merge: WorktreeMergeEntry(entry: merged, isRechecking: true),
                                        info: .init(), targetNames: ["main", "dev"], isChecking: false)
        // A commit in a row that isn't open: the list already has the new HEAD.
        let headMoved = status(merged, worktree: Worktree(path: "/feature", branch: "feature", head: "def"))
        for stale in [rechecking, headMoved] {
            #expect(stale.mark == .notMerged)
            #expect(stale.group == .merged)
            #expect(!stale.showsTrash)
            #expect(stale.card.title == "Checking…")
            #expect(stale.card.subtitle == "Looking for this branch in main or dev.")
            #expect(facts(stale)[1] == "Checking merge status…")
            // Inside the group the ring stays, so the row says why it has no trash.
            #expect(stale.rowMark(grouped: true) == .notMerged)
            #expect(stale.hasHoverCard(grouped: true))
        }
        // Uncommitted work and agents still outrank it; the merge fact still says checking.
        let dirty = WorktreeStatus(worktree: feature, merge: WorktreeMergeEntry(entry: merged, isRechecking: true, localChangeCount: 1),
                                   info: .init(), targetNames: ["dev"], isChecking: false)
        #expect(dirty.mark == .uncommitted)
        #expect(facts(dirty)[1] == "Checking merge status…")
    }

    @Test("merged but protected keeps its title and says why in the sentence, not as extra facts")
    func mergedButProtected() {
        let locked = Worktree(path: "/locked", branch: "locked", isLocked: true)
        let lockedStatus = status(entry(locked, merged: [dev]) { $0.problem = "Locked worktree" })
        // Not "Safe to delete": the ring and the Not merged group, and the card says why.
        #expect(lockedStatus.mark == .notMerged)
        #expect(lockedStatus.group == .notMerged)
        let card = lockedStatus.card
        #expect(card.title == "Merged")
        #expect(card.subtitle == "Locked, so Teebe won’t remove it.")
        #expect(card.facts.map(\.text) == ["No uncommitted changes", "Merged into dev", "Not on remote"])
        let primary = Worktree(path: "/repo", branch: "feature", isPrimary: true)
        #expect(status(entry(primary, merged: [dev])).card.subtitle == "The main checkout, so Teebe won’t remove it.")
        let detached = Worktree(path: "/d", head: "abc", isDetached: true)
        let detachedStatus = status(entry(detached, merged: [dev]) { $0.problem = "Detached HEAD" })
        #expect(detachedStatus.card.subtitle == "Detached HEAD, so Teebe won’t remove it.")
        #expect(detachedStatus.group == .notMerged)
        #expect(detachedStatus.mark == .notMerged)
        // Merged commits, but Git could be hiding local work: no ✓, and the sentence says why.
        let skipped = status(entry(merged: [dev]) { $0.hasUncheckedFiles = true })
        #expect(skipped.card.title == "Merged")
        #expect(skipped.card.subtitle == "Some files are marked unchanged in Git, so Teebe won’t remove it.")
        #expect(facts(skipped) == ["No uncommitted changes", "Merged into dev", "Not on remote"])
        #expect(status(entry(merged: [dev]) { $0.hasSubmodules = true }).card.subtitle
                == "It contains a submodule, so Teebe won’t remove it.")
        // Ignored files are ordinary clutter on hover; they only matter at removal.
        let ignored = status(entry(merged: [dev]) { $0.hasIgnoredFiles = true; $0.ignoredPaths = [".build/"] })
        #expect(facts(ignored) == ["No uncommitted changes", "Merged into dev", "Not on remote"])
    }

    @Test("the removal prompt offers branch deletion only when the work is already merged")
    func removalPrompt() {
        let merged = entry(merged: [dev])
        let safe = WorktreeRemovalPrompt(worktree: feature, status: status(merged), merge: WorktreeMergeEntry(entry: merged))
        #expect(safe.title == "Remove “feature”?")
        #expect(safe.facts.map { $0.text } == ["Merged into dev", "Nothing uncommitted"])
        // One merge glyph everywhere; green only when the fact says merged.
        #expect(safe.facts[0] == WorktreeCardFact(icon: .merge, text: "Merged into dev", tone: .positive))
        #expect(safe.explanation == "The worktree folder is deleted. Its commits are already merged.")
        #expect(safe.offersBranchDeletion)

        let cluttered = entry(merged: [dev]) { $0.hasIgnoredFiles = true; $0.ignoredPaths = [".DS_Store", ".cache/"] }
        let withIgnored = WorktreeRemovalPrompt(worktree: feature, status: status(cluttered),
                                                merge: WorktreeMergeEntry(entry: cluttered))
        #expect(withIgnored.facts.last == WorktreeCardFact(icon: .ignoredFiles,
                                                           text: "Ignored files will be deleted too (.DS_Store)", tone: .muted))

        let unmerged = entry()
        let risky = WorktreeRemovalPrompt(worktree: feature, status: status(unmerged, count: 2, info: .init(agentState: .working)),
                                          merge: WorktreeMergeEntry(entry: unmerged, localChangeCount: 2))
        // Removal is never forced: Git refuses a folder with uncommitted work, so
        // nothing is "lost" and Remove is not offered until it is committed or discarded.
        #expect(risky.facts.map { $0.text } == ["Not merged yet", "2 uncommitted changes: commit or discard them first",
                                            "An agent is working here"])
        #expect(risky.facts[1].tone == .warn)
        #expect(risky.facts[0] == WorktreeCardFact(icon: .merge, text: "Not merged yet", tone: .muted))
        #expect(risky.explanation == "Git only removes a worktree with nothing uncommitted. The branch is kept.")
        #expect(!risky.canRemove)
        #expect(!risky.offersBranchDeletion)
        #expect(safe.canRemove)

        let unmergedClean = WorktreeRemovalPrompt(worktree: feature, status: status(unmerged),
                                                  merge: WorktreeMergeEntry(entry: unmerged))
        #expect(unmergedClean.facts.map { $0.text } == ["Not merged yet", "Nothing uncommitted"])
        #expect(unmergedClean.explanation == "The worktree folder is deleted. The branch is kept.")
        #expect(unmergedClean.canRemove)

        let submodule = entry(merged: [dev]) { $0.hasSubmodules = true }
        let nested = WorktreeRemovalPrompt(worktree: feature, status: status(submodule),
                                           merge: WorktreeMergeEntry(entry: submodule))
        #expect(nested.facts.map { $0.text } == ["Merged into dev", "Nothing uncommitted",
                                             "Contains a submodule: Git won’t remove it"])
        #expect(nested.explanation
                == "Git won’t remove a worktree that contains a submodule without forcing it, and Teebe never forces.")
        #expect(!nested.canRemove)
        #expect(!nested.offersBranchDeletion)
    }

    @Test("the removal prompt won't remove while anything is working there, and says what")
    func removalPromptActivity() {
        let merged = entry(merged: [dev])
        func prompt(_ info: SelectorModel.WorktreeInfo) -> WorktreeRemovalPrompt {
            WorktreeRemovalPrompt(worktree: feature, status: status(merged, info: info), merge: WorktreeMergeEntry(entry: merged))
        }
        let explanation = "Teebe won’t remove a worktree while something is working in it. Try again when it’s done."
        for (info, text) in [(SelectorModel.WorktreeInfo(agentState: .working), "An agent is working here"),
                             (SelectorModel.WorktreeInfo(agentState: .needsAttention), "An agent is waiting for you here"),
                             (SelectorModel.WorktreeInfo(isLive: true), "Files are changing or a command is running here")] {
            let active = prompt(info)
            #expect(active.facts.last == WorktreeCardFact(icon: .warning, text: text, tone: .warn))
            #expect(!active.canRemove)
            #expect(!active.offersBranchDeletion)
            #expect(active.explanation == explanation)
        }
    }

    @Test("the removal prompt won't remove what Git protects or hides, or a row still being checked")
    func removalPromptBlockers() {
        let locked = Worktree(path: "/locked", branch: "locked", isLocked: true)
        let lockedEntry = entry(locked) { $0.problem = "Locked worktree" }
        let lockedPrompt = WorktreeRemovalPrompt(worktree: locked, status: status(lockedEntry),
                                                 merge: WorktreeMergeEntry(entry: lockedEntry))
        #expect(lockedPrompt.facts.last == WorktreeCardFact(icon: .warning, text: "Locked, so Teebe won’t remove it", tone: .warn))
        #expect(!lockedPrompt.canRemove)
        #expect(lockedPrompt.explanation == "Teebe only removes a worktree Git can fully check and nothing protects.")
        let hidden = entry { $0.hasUncheckedFiles = true }
        let hiddenPrompt = WorktreeRemovalPrompt(worktree: feature, status: status(hidden), merge: WorktreeMergeEntry(entry: hidden))
        #expect(hiddenPrompt.facts.last?.text == "Some files are marked unchanged in Git, so Teebe won’t remove it")
        #expect(!hiddenPrompt.canRemove)

        let checking = WorktreeRemovalPrompt(worktree: feature, status: status(nil, isChecking: true), merge: nil)
        #expect(checking.facts.first == WorktreeCardFact(icon: .merge, text: "Checking if merged…", tone: .muted))
        #expect(!checking.canRemove)
        #expect(checking.explanation == "Teebe is still checking this worktree. Try again in a moment.")
        let merged = entry(merged: [dev])
        let rechecking = WorktreeMergeEntry(entry: merged, isRechecking: true)
        let stale = WorktreeRemovalPrompt(
            worktree: feature,
            status: WorktreeStatus(worktree: feature, merge: rechecking, info: .init(), targetNames: ["dev"], isChecking: false),
            merge: rechecking)
        #expect(!stale.canRemove)
        #expect(!stale.offersBranchDeletion)
    }

    @Test("removing a folder whose .git link is missing is refused, and the prompt says why")
    func brokenLinkPrompt() {
        let unlinked = entry(feature) { $0.isBroken = true }
        let prompt = WorktreeRemovalPrompt(worktree: feature, status: status(unlinked),
                                           merge: WorktreeMergeEntry(entry: unlinked))
        #expect(!prompt.canRemove)
        #expect(!prompt.offersBranchDeletion)
        #expect(prompt.facts.contains(WorktreeCardFact(icon: .warning, text: "Its .git link is missing, so Teebe won’t remove it",
                                                       tone: .warn)))
        #expect(prompt.explanation == "Teebe only removes a worktree Git can fully check and nothing protects.")
    }

    @Test("the ignored-files fact names at most one short example")
    func ignoredFact() {
        func entryWith(_ paths: [String]) -> CleanupEntry { entry { $0.hasIgnoredFiles = !paths.isEmpty; $0.ignoredPaths = paths } }
        #expect(WorktreeWording.ignoredFact([entryWith([])]) == nil)
        #expect(WorktreeWording.ignoredFact([entryWith([]), entryWith([".build/"])])?.text
                == "Ignored files will be deleted too (.build/)")
        #expect(WorktreeWording.ignoredFact([entryWith(["a/very/long/path/to/some/cache/file.bin"])])?.text
                == "Ignored files will be deleted too (a/very/l…file.bin)")
    }

    @Test("lists read naturally")
    func wordingLists() {
        #expect(WorktreeWording.list(["dev"]) == "dev")
        #expect(WorktreeWording.list(["dev", "main"]) == "dev and main")
        #expect(WorktreeWording.list(["dev", "develop", "main"], joiner: "or") == "dev, develop or main")
    }
}
