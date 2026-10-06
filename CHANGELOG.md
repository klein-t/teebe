# Changelog

All notable changes to teebe are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

## [0.8.0] - 2026-10-06

### Added
- **Worktree status at a glance.** Each worktree shows a single mark: an
  animated orb while a coding agent is working in it, an orange dot for
  uncommitted changes, a ring when its commits are not merged yet, and a green
  check when it is merged and safe to delete. Hover the mark for a short card
  that explains it.
- **Automatic merge detection.** teebe checks every worktree against your
  default branch plus dev, develop, main and master, and an extra comparison
  branch you can choose. Squash merges count as merged, and so do branches
  merged commit by commit when every change matches exactly, spacing and
  position included. Brand new branches never do.
- **Grouping, sorting and cleanup.** Group worktrees by state (uncommitted, not
  merged, safe to delete) and sort them by status, name or folder. Remove a
  single worktree from the bin on its row, or every worktree that is safe to
  delete in one step, after a confirmation that lists each one. The branch can
  be deleted along with it. Commits that only the worktree's history still
  reached, for example after a reset, are kept in a hidden backup so nothing
  becomes unrecoverable.
- **New Worktree sheet.** Create a worktree on a new or existing branch, pick
  its starting point and choose where its folder goes. The location is
  suggested from your existing worktrees and remembered.
- **Background fetch.** teebe can quietly fetch from origin in the background
  so sync arrows and merge status stay current. Refresh fetches right away and
  tells you when the remote can't be reached, with a Retry button.
- **Claude Code and Codex activity.** Worktrees show when Claude Code or Codex
  is working or waiting in them, along with activity from other tools working
  inside a worktree.
- **Agent notification controls.** Settings now has switches for completion
  notifications and their sound, a Test Notification button, and the status of
  the optional Claude Code hook. Notifications are off by default for new
  installs, and stay on if you already had teebe.
- **Search the whole repository.** File search in Files now reaches folders
  you haven't opened yet, without blocking the window.
- **More file commands.** Copy a file's full or relative path, collapse every
  open folder in one click, and press Space for Quick Look.
- **Pinned folders.** While you scroll through Files, the open folders you are
  inside stay pinned at the top.
- **Open files your way.** The first time you open a file type, teebe asks
  which app to use and remembers it. Settings lists remembered file types so
  you can change or forget them.
- **Arrow keys while previewing.** While a preview is open, the arrow keys move
  to the previous or next file, and Left and Right collapse and expand folders.
- **Global defaults, project overrides.** Settings holds your defaults, and
  choices made inside a project apply to that project only, until you return
  it to the defaults. This covers the terminal (Terminal or cmux), how files
  open, the comparison branch and where new worktrees go.
- A setting to turn automatic update checks off. Check for Updates still works
  when they are off.
- Hover explanations for file status badges, toolbar buttons and group
  headings. They also work while another app is in front.

### Changed
- **Translucent window background.** The window now has a translucent,
  Finder-style background in both light and dark mode.
- Lower CPU use: agent animations stop drawing when they are scrolled out of
  view or the window is hidden, and background scanning does less work.
- teebe starts faster when you have many old Codex sessions.
- Switching worktrees keeps the previous changes on screen until the new ones
  have loaded, so the window no longer jumps.
- While teebe is hidden, Codex completions are checked every 15 seconds, so
  short turns are noticed promptly.

### Fixed
- Opening a very large text file could freeze the app for many seconds. Large
  previews now open right away, with an option to open the file in its default
  app.
- Moving through Files could leave several rows highlighted at once.
- File search keeps keyboard focus, follows your .gitignore rules, remembers
  your filters and no longer flickers while the worktree refreshes.
- Agent notifications never appeared as banners while teebe was in front.
- Switching projects quickly could show the previous project's worktrees.
- Merge status could stay stale after a fetch or a branch change made while
  teebe was hidden, including when you showed and hid teebe again quickly.
- Background fetches could trigger surprise approval prompts from SSH agents
  such as 1Password or Secretive. They now never use an SSH agent, even when a
  repository's own SSH command names one, and stay silent; Refresh still uses
  it. Repositories that use a custom SSH wrapper are skipped in the background.
  Clicking Refresh during a background fetch waits for it instead of reporting
  an error.
- A new branch created with a worktree tracked its starting branch, so a plain
  `git push` could fail or push to the wrong branch. New branches now start
  without an upstream.
- If you switched projects while a new worktree was being created, teebe
  jumped back to the project it was created in.
- Finishing a cancelled worktree creation could close a New Worktree sheet you
  had opened since, losing what you had typed.
- A comparison branch typed by name in Settings was never checked.
- A worktree with an unfinished rebase, merge or similar Git operation could
  be offered for removal. It is now never removable, and a worktree that
  couldn't be checked says so instead of looking clean.
- A worktree whose ignored files contain a Git repository with commits of its
  own could be offered for removal. It is now never removable.
- The removal confirmation now says clearly how many ignored files will be
  deleted for good.
- A status card opened from the keyboard kept popping up again on its own.
- Error and notice rows pushed Files below the bottom of the window. The window
  now grows to fit them.
- Discard, stage and unstage could act on the wrong worktree while a newly
  selected one was still loading, and an open discard confirmation could apply
  to the worktree you switched to.
- Installing the Claude Code hook could overwrite other hook settings it
  didn't understand. Those settings are now left untouched.
- A settings file that couldn't be read could be overwritten and lose your
  projects and preferences. It is now kept aside.
- What's New could appear again for a release you had already seen.

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
