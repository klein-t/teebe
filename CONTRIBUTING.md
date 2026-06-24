# Contributing to teebe

Thanks for your interest. This is an early-stage, test-driven macOS project.

## Prerequisites

- macOS 14+
- A Swift 6 toolchain (the package builds in Swift 5 language mode)
- [SwiftLint](https://github.com/realm/SwiftLint) (`brew install swiftlint`)

## Build & test

```sh
swift build           # builds TeebeCore + the Teebe app
swift test            # runs the Swift Testing suite (unit + git integration)
swift run Teebe  # launches the app
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
   git worktree add ../teebe-<name> -b feat/<name> dev
   ```
2. Keep changes focused. This codebase is test-first — add or update tests for
   any behavior change in `TeebeCore` or the view models.
3. Run `swift test` and `swiftlint lint` locally before pushing.
4. Open a pull request into **`dev`** (never directly into `main`). CI (build,
   test, lint, CodeQL) must be green before merge.
5. `main` is release-only: it's updated by merging `dev`, then tagging `vX.Y.Z`
   to cut a release.

## Commit messages

Use short, imperative summaries (e.g. `Fix peek top-gap`). Group related work
into a single commit where it makes sense.

## Architecture

`TeebeCore` stays pure and UI-independent; the app target holds thin views
+ `@Observable` view models.

## Contributor License Agreement

Teebe is dual-licensed (GPL-3.0-or-later and a commercial license). Before your
first contribution is merged, you must agree to the
[Contributor License Agreement](CLA.md). In practice: include a
`Signed-off-by:` line in your commits (`git commit -s`) and state in your first
PR that you agree to the CLA. This lets the project stay offerable under both
licenses.

## Shipping updates (Sparkle)

teebe self-updates via [Sparkle](https://sparkle-project.org). Updates are
delivered through an **appcast** (`appcast.xml`). The app's `SUFeedURL` points at
**`https://teebe.io/appcast.xml`** — hosted on our own domain (the `teebe-site`
GitHub Pages repo) so the feed URL baked into shipped binaries is
host-independent. The appcast's `.app` zip enclosures still live on GitHub
Releases. Each update is integrity-signed with an **EdDSA key** — this is
Sparkle's own signature and is independent of Apple notarization (which governs
first-launch Gatekeeper trust, not updates).

### One-time signing-key setup (maintainer)

Sparkle ships a `generate_keys` tool (in the resolved package under
`.build/artifacts/sparkle/Sparkle/bin/`). Run it once **in your Terminal** (it
stores the private key in the login Keychain):

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys      # prints the public key
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle_private.key   # export for CI
```

Then add these to the GitHub repo (Settings → Secrets and variables → Actions):

- `SPARKLE_PUBLIC_ED_KEY` — the public key string (embedded in `Info.plist` at
  build time via `SU_PUBLIC_ED_KEY`).
- `SPARKLE_ED_PRIVATE_KEY` — the contents of `sparkle_private.key` (used by CI
  to sign the appcast). Treat it like any signing secret; do not commit it.

Delete `sparkle_private.key` after adding the secret. The private key is the
root of update trust — if it leaks, rotate it (new keypair, new public key in
the next release).

### What happens on release

The Release workflow builds the `.app` (stamping the tag as `CFBundleVersion`,
which is what Sparkle compares to detect a newer version), zips it, runs
`generate_appcast` (signing each update with the private key), and uploads both
the zip and `appcast.xml` to a **draft** release.

**Publishing the draft is what ships the update.** Publishing fires the
`publish-appcast` workflow, which pushes that release's signed `appcast.xml` into
the `teebe-site` repo so it's served at `https://teebe.io/appcast.xml` (where
`SUFeedURL` points). Until you publish, the appcast on teebe.io still points at
the previous release, so existing apps see nothing new. Once published, existing
users get an in-app "Update available" prompt; the menu also has **Check for
Updates…**.

> The `publish-appcast` workflow needs a repo secret **`SITE_DEPLOY_TOKEN`** — a
> fine-grained PAT scoped to `klein-t/teebe-site` with *Contents: read and write*
> — so CI can commit the appcast to that repo.

> Note: until the app is Developer ID-signed and **notarized**, first-time
> downloads still hit Gatekeeper (right-click → Open). Notarization is separate
> from Sparkle and tracked independently.

## Security

Never commit secrets. See [`SECURITY.md`](SECURITY.md) for the reporting policy
and secrets hygiene.
