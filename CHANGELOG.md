# Changelog

All notable changes to teebe are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

## [0.7.0] - 2026-09-02

### Added
- **Settings window** (⌘,) with an Appearance picker: follow the system, or
  force Light or Dark. The choice applies immediately and persists.
- The About panel now links to teebe.io, the GitHub repo and the author's X
  account.

### Fixed
- A pinned window never showed up in App Exposé or Mission Control. It now
  floats only while another app is in front, so it is listed whenever teebe is
  active; behaviour while working in other apps is unchanged.
- With the window pinned, closing the About panel with ⌘W could get the app
  quit a second later by window-tracking utilities that overlook floating
  windows. Same fix as above, plus a guard in the app's own last-window check.

## [0.6.0] - 2026-08-07

### Added
- **Low-power mode.** When teebe's window is covered, every file watcher stops
  and the app idles at near-zero CPU — while "agent needs you" notifications
  keep arriving, now instantly, via a tiny Claude Code hook (`notifyutil` ping
  on turn end). teebe offers to add the hook once at launch; declining keeps
  everything working the old way.

### Fixed
- Under a continuous stream of agent writes the tree could stop updating until
  the burst ended (the debounce never fired). Updates now land at least every
  couple of seconds no matter how busy the agents are.
- A session log whose scanned tail started mid-emoji (or mid-character) was
  silently read as "no agent" — the worktree dot went gray while the agent was
  actually working.

### Changed
- Session-log scanning is lighter: timestamp parsers are built once instead of
  per line, and only the last relevant lines of each log are decoded.

## [0.5.1] - 2026-08-04

### Fixed
- Picking an already-tracked folder from the add (+) panel now switches to that
  repository instead of silently doing nothing.
- The CHANGES count no longer rolls its digits when you switch worktrees — it
  snaps to the new worktree's total, and still animates when changes happen in
  the current worktree.
- Agent status now follows the worktree the agent is actually working in. A
  session that starts in the main checkout and moves into a linked worktree
  used to show as activity on the main checkout.

### Changed
- The "working" / "needs you" chip is gone; the worktree dot now tells the
  whole story — pulsing green while an agent is working, steady amber when it
  needs you, gray when nothing is happening there.

## [0.5.0] - 2026-07-28

### Added
- **Agent status per worktree.** Each worktree now shows what its AI agent is
  doing, "working" while a session is mid-turn and "needs you" once the turn
  ends or stalls, with a notification when an agent finishes and is waiting on
  you.

### Fixed
- The green live-activity dot no longer stays lit forever after a single file
  change. It now goes out a few seconds after the last write, which also stops
  a pulse animation that kept running in the background and used CPU while the
  app was idle.

### Changed
- The macOS folder-access prompt now explains why teebe needs access to your
  repositories, and the privacy notice spells out that everything stays on
  your Mac.

## [0.4.2] - 2026-07-16

### Fixed
- The FILES section no longer leaves an empty strip at the bottom of the window,
  and the file tree no longer snaps upward when a window resize ends.
- Git failures now show a short human-readable message instead of a raw
  technical error dump.

### Changed
- CHANGES rows now use the same per-type file icons as the FILES tree.
- The "↓0 ↑0" sync indicator is hidden when there is nothing to pull or push,
  and no longer appears in the CHANGES header.
- Tidier section headers: unified icon sizes, typography and alignment across
  sections.

## [0.4.1] - 2026-07-01

### Fixed
- Deleting a file (Move to Trash) or discarding changes no longer silently does
  nothing after you confirm it in the dialog.

## [0.4.0] - 2026-06-30

### Added
- **Keyboard navigation.** Drive the whole window without the mouse. Arrow keys move
  through Worktrees, Changes and Files. `⌘1` / `⌘2` / `⌘3` focus a section (press again
  to collapse), and `Tab` cycles between them. `Return` opens a file or switches
  worktree, and `Space` Quick Looks a file or peeks a diff.
- **Multi-select and send to your agent.** Select several files with `⌘`- or `⇧`-click,
  `⇧↑` / `⇧↓`, or `⌘A`. Copy them as AI-agent-ready `@`-refs with `⌘⇧C`, or move them to
  the Trash with `⌘⌫`.
- **Automatic worktree detection.** Worktrees you add or remove outside teebe (for
  example with `git worktree add` in a terminal) now appear on their own, with no
  manual action. The Refresh button forces a full re-scan.
- **Keyboard Shortcuts cheat sheet.** Press `?` (or open Help → Keyboard Shortcuts) for
  the full list.
- **Jump to search** with `⌘F`.
- **What's New window.** Shows this changelog inside the app: automatically on the
  first launch after an update, and any time from Help → What's New.

### Changed
- **Bounded section sizing.** The Worktrees and Changes lists now scroll inside their
  own area once they get tall, instead of growing without limit. The window stays a
  stable size as you switch between worktrees.
- **Vertical maximize.** The green window button now grows teebe to the full screen
  height at its current width (filling with the file tree) instead of zooming to cover
  the whole screen. Click it again to restore the previous size.

### Fixed
- Folders in the file tree now show a folder icon instead of a flat blue square.

## [0.3.0] - 2026-06-24

### Changed
- Window resizing reworked into a coherent content-wrap model: no more
  bounce / jump / gap on resize.

### Added
- Branded `.dmg` download for the website, with centered teebe / Applications icons.
- The Sparkle appcast is now hosted on teebe.io; releases also ship a stable
  `teebe-macos.zip` asset.

### Fixed
- Dock icon rendering, updater start-up, and a sticky error banner.

## [0.2.2] - 2026-06-23

### Fixed
- **Packaged-app launch crash.** v0.2.0 / v0.2.1 release builds crashed on launch
  ("could not load resource bundle") because the resource bundle wasn't resolvable
  in a code-signed `.app`. The app now resolves it from `Contents/Resources`.

## [0.2.1] - 2026-06-23

### Changed
- The CHANGES section now hugs its rows like WORKTREES instead of taking the
  flexible vertical space; FILES is the sole space-filling section, and the
  window resizes as the change count changes.

## [0.2.0] - 2026-06-23

### Added
- Sparkle in-app auto-updates.

### Fixed
- Section-toggle bounce; refined sidebar chrome.

## [0.1.0] - 2026-06-23

### Added
- Initial release: browse a git repository's worktrees, changes, and files.
