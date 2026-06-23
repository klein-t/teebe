# Security Policy

## Supported versions

Teebe is in active development (pre-1.0). Security fixes are applied to the
`main` branch only. There are no long-term-support branches yet.

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Report privately via GitHub's [private vulnerability
reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
(the **Security → Report a vulnerability** tab on this repository), or email
**klein.tahiraj@gmail.com**.

Please include:

- A description of the issue and its impact.
- Steps to reproduce (a proof-of-concept if possible).
- Affected commit / version.

You can expect an acknowledgement within a few days. Once a fix is ready we will
coordinate disclosure.

## Scope & threat model

Teebe is a local, sandboxed macOS app that browses git repositories and
worktrees on your machine. It:

- Stores **no credentials and no secrets**. Persisted state is limited to UI
  preferences and last-opened paths.
- Shells out to the system `git` and opens files in their native apps; it does
  not transmit your code or repository contents anywhere.

Security-relevant areas worth scrutiny: command construction around the `git`
subprocess, path handling / traversal in file operations, and parsing of
untrusted repository contents (diffs, status porcelain, branch/worktree lists).

## Secrets hygiene

Real secrets must never be committed. This repo enforces that with:

- A `.gitignore` that excludes `.env*`, key/cert material, and `secrets.*`.
- GitHub **secret scanning + push protection** enabled on the remote.

If you believe a secret was committed, treat it as compromised: rotate it at the
provider immediately, then scrub it from history.
