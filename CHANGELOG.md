# Changelog

All notable changes to teebe are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

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
- Window resizing reworked into a coherent content-wrap model — no more
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
  flexible vertical space — FILES is the sole space-filling section, and the
  window resizes as the change count changes.

## [0.2.0] - 2026-06-23

### Added
- Sparkle in-app auto-updates.

### Fixed
- Section-toggle bounce; refined sidebar chrome.

## [0.1.0] - 2026-06-23

### Added
- Initial release: browse a git repository's worktrees, changes, and files.
