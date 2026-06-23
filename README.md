# teebe

A native macOS file browser built for the multi-agent era.

> The product name is **teebe**. The Swift package and modules keep the
> `Treebranch` / `TreebranchCore` identifiers for now.

When you have several AI coding agents (Claude Code, Codex/CMAX, etc.) working in
parallel across git worktrees, **teebe** is the calm control room that shows
you — across all your repos and worktrees — what files exist, what's changing, and
what's about to ship. It does not replace your editor: it's the navigator that
launches files into whatever native app you already use.

> Status: in development. `TreebranchCore` (git layer, parsers, services, file
> watcher, file ops, write queue) and the app's view models are implemented and
> tested; the SwiftUI shell is functional and wired (visual design in progress).

## Build & test

```sh
swift build           # builds TreebranchCore + the Treebranch app
swift test            # runs the Swift Testing suite (unit + git integration)
swift run Treebranch  # launches the app
```

Requires macOS 14+ and a Swift 6 toolchain (built in Swift 5 language mode). Git
integration tests shell out to the system `git` against throwaway temp repos.

## Project layout

- `Sources/TreebranchCore/` — pure, UI-independent core: models, `GitClient`
  (+ `ProcessGitClient`), porcelain/diff/worktree/branch parsers, services,
  `FileTreeBuilder`, `FSEventsWatcher`, file ops, `RepoGitQueue`.
- `Sources/Treebranch/` — SwiftUI app: `@Observable` view models + thin views.
- `Tests/` — Swift Testing suites (`TreebranchCoreTests`, `TreebranchTests`),
  protocol fakes, and a `GitFixture` real-git harness.

## Why

There's no open-source, Finder-like, **worktree- and branch-aware** file browser.
Existing tools are either git clients centered on a single repo (Fork, Sublime
Merge), terminal TUIs (lazygit), or agent-session managers (Crystal, Conductor).
None give you a live, cross-worktree "mission control" of what your agents are
touching right now.

## What it is (v1)

- A **tree navigator**, not an editor. Click a file → it opens in its native app.
- **Worktree-aware**: pick any worktree of any repo and see its files.
- **Git-aware**: changed files are badged; a Changes view shows working changes
  and what's "about to ship" (diff vs base branch), with inline read-only diffs.
- **Live**: the tree and badges update in real time (FSEvents) as agents write.
- **Multi-repo**: add several repos; an Overview shows all worktrees at once.
- **Read-write** at the file-management level (rename/move/trash/new) and the git
  level (stage/discard/commit/checkout). Content editing is delegated to native apps.

## What it is not (v1)

- Not a code editor (no in-app content editing).
- Not a full git client (no rebase / cherry-pick / merge-conflict UI).
- Not cross-platform (macOS only).
- Not an agent orchestrator (agent ↔ worktree mapping is a v2 integration).

## License

MIT (proposed).
