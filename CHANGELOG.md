# Changelog

All notable changes to teebe are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Worktrees added or removed **outside** teebe (e.g. `git worktree add` / `remove`
  in a terminal) are now detected automatically and appear in the WORKTREES list
  without a manual action. The Refresh button forces a full re-scan.
- A **What's New** window that shows this changelog inside the app — opened
  automatically the first time you launch a new version, and any time from
  Help → What's New.

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
