# Privacy

teebe is a local macOS app. Short version: we count downloads and website page
views in aggregate so we know roughly how many people are interested in teebe,
and that's it. No accounts, no personal data, no tracking of what you do inside
the app.

The canonical, always-current version of this notice lives at
**https://teebe.io/privacy.html**.

## What we collect

When you install teebe, the download is served through `dl.teebe.io`, which
records one anonymous, aggregate event:

- the app **version** you downloaded,
- your **country** (derived at the edge, not stored as a precise location), and
- the **user-agent** string your downloader sends.

When you open a page on `teebe.io`, a small script records one anonymous,
aggregate page-view event: the **page** you viewed, the **referring site** (if
any), and your **country**. To tell a fresh visit from a page-to-page click we
keep a single per-tab flag in your browser's `sessionStorage` — it holds no
identifier and is gone when you close the tab.

We use all of this only to gauge interest and adoption. It is not tied to your
identity and is not sold or shared.

## What we don't collect

- We do **not** store your IP address.
- We do **not** track anything you do inside the app — teebe contains no in-app
  analytics or telemetry.
- We do **not** use cookies or ad trackers.
- We have no accounts, so there is no personal profile to collect.

## Updates

teebe checks for new versions via [Sparkle](https://sparkle-project.org/), which
fetches an update feed from teebe.io. These are ordinary web requests subject to
standard server logs; they are not used to profile you.

## If this ever changes

If we ever add in-app analytics, it will be **opt-in** and this notice will be
updated first.

## Contact

Questions? Open an issue on [GitHub](https://github.com/klein-t/teebe).
