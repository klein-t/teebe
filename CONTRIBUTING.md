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

1. Open or reuse an issue describing the problem and acceptance criteria.
2. Create an isolated sibling worktree from updated `origin/dev`, for example:
   ```sh
   git fetch origin
   git worktree add ../teebe-files -b fix/123-file-preview origin/dev
   ```
3. Keep one coherent purpose per commit and one independently reviewable outcome
   per PR. Include regression tests with behavior changes.
4. Run `swift build`, `swift test`, and `swiftlint lint`. Lint must have no errors
   or new warnings; report existing warning debt rather than claiming zero
   warnings. For UI changes, verify the packaged app as well as native tests.
5. Open the PR into `dev`, linking its issue. Required checks are Build & Test
   (macOS), SwiftLint, and PR Title. CodeQL is currently manual-only, not a
   required merge gate. Verify checks on the final head before merging.
6. Squash new independent feature PRs, using the curated PR title as the commit
   subject. Existing dependent stacks may use merge commits deliberately.
   `dev` to `main` releases require a regular merge commit, never squash.
7. `main` is release-only. Update version and changelog, verify the packaged
   artifact, and follow the release process below before publishing.

## Commit and PR titles

Use English [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/):
`type(scope): imperative description`. Scope is optional and names a stable area.
Allowed types: `feat`, `fix`, `perf`, `refactor`, `test`, `docs`, `build`, `ci`,
`chore`, and `revert`.

Aim for at most 72 characters. Describe the behavior or problem, without a
trailing period, emoji, `WIP`, or vague summaries such as `fix bugs`. Use Draft
PRs for unfinished work. Mark actual compatibility breaks with `!` or a
`BREAKING CHANGE:` footer and explain migration. Do not rewrite existing
published history just to change its naming.

```
fix(files): use native Quick Look from the context menu
feat(settings): add per-project preference overrides
ci: validate pull request titles
```

## PR descriptions and evidence

Lead with the problem and resulting behavior. Include checks actually run,
results, and material limitations. A simple change needs only a short summary
and validation. Distinguish automated tests, simulated dependencies, native UI
checks, and packaged-app verification. Do not mark pending checks as passing.

Use `Fixes #123` when the PR fully resolves the issue, otherwise `Refs #123`.
Declare necessary dependencies with `Depends on #123`; inspect the final diff
for duplicated or unrelated changes before integration. Rewrite the title and
body if scope changes. Exclude chronological work logs and private tooling notes.

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
**`https://teebe.io/appcast.xml`**, hosted on our own domain (the `teebe-site`
GitHub Pages repo) so the feed URL baked into shipped binaries is
host-independent. The appcast's `.app` zip enclosures still live on GitHub
Releases. Each update is integrity-signed with an **EdDSA key**; this is
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

- `SPARKLE_PUBLIC_ED_KEY`: the public key string (embedded in `Info.plist` at
  build time via `SU_PUBLIC_ED_KEY`).
- `SPARKLE_ED_PRIVATE_KEY`: the contents of `sparkle_private.key` (used by CI
  to sign the appcast). Treat it like any signing secret; do not commit it.

Delete `sparkle_private.key` after adding the secret. The private key is the
root of update trust; if it leaks, rotate it (new keypair, new public key in
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

> The `publish-appcast` workflow needs a repo secret **`SITE_DEPLOY_KEY`**: the
> private half of an SSH **deploy key** whose public half is installed on
> `klein-t/teebe-site` with write access. A deploy key is scoped to that single
> repo and isn't tied to a personal account, so a leak can only push to
> teebe-site and nothing else. To rotate: delete the deploy key on teebe-site,
> generate a new `ed25519` keypair, add the public half as a write deploy key,
> and replace the `SITE_DEPLOY_KEY` secret with the new private half.

> Note: until the app is Developer ID-signed and **notarized**, first-time
> downloads still hit Gatekeeper (right-click → Open). Notarization is separate
> from Sparkle and tracked independently.

## Security

Never commit secrets. See [`SECURITY.md`](SECURITY.md) for the reporting policy
and secrets hygiene.
