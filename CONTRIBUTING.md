# Contributing to treebranch

Thanks for your interest. This is an early-stage, test-driven macOS project.

## Prerequisites

- macOS 14+
- A Swift 6 toolchain (the package builds in Swift 5 language mode)
- [SwiftLint](https://github.com/realm/SwiftLint) (`brew install swiftlint`)

## Build & test

```sh
swift build           # builds TreebranchCore + the Treebranch app
swift test            # runs the Swift Testing suite (unit + git integration)
swift run Treebranch  # launches the app
swiftlint lint        # lint (CI runs this too)
```

Git integration tests shell out to the system `git` against throwaway temp repos,
so a working `git` must be on your `PATH`.

## Workflow

This repo uses a feature → `dev` → `main` branch model, and feature work happens
in **git worktrees**. In short:

1. Branch off **`dev`** (the default branch) into a worktree, using a descriptive
   prefix: `feat/…`, `fix/…`, `chore/…`, `docs/…`, `test/…`:
   ```sh
   git switch dev && git pull
   git worktree add ../treebranch-<name> -b feat/<name> dev
   ```
2. Keep changes focused. This codebase is test-first — add or update tests for
   any behavior change in `TreebranchCore` or the view models.
3. Run `swift test` and `swiftlint lint` locally before pushing.
4. Open a pull request into **`dev`** (never directly into `main`). CI (build,
   test, lint, CodeQL) must be green before merge.
5. `main` is release-only: it's updated by merging `dev`, then tagging `vX.Y.Z`
   to cut a release.

## Commit messages

Use short, imperative summaries (e.g. `Fix peek top-gap`). Group related work
into a single commit where it makes sense.

## Architecture

`TreebranchCore` stays pure and UI-independent; the app target holds thin views
+ `@Observable` view models.

## Security

Never commit secrets. See [`SECURITY.md`](SECURITY.md) for the reporting policy
and secrets hygiene.
