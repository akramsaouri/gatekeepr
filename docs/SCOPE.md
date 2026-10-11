# gatekeepr: scope

Shows when your Appgate SDP session on macOS will expire, as a CLI and a menu bar app. Public GitHub repo, MIT licence.

## Why
Claude Code goes through Vend's gateway, which sits behind Appgate. Appgate doesn't show when the session expires, so Claude just stops working, and you only get a 5-minute warning before it does.

## How detection works
There's no API for this. gatekeepr works it out from `/var/log/appgate/driver.log` and the rotated `driver-*.log.gz` files, which any user can read. It needs no root and makes no network calls.

- **Real sign-in:** a `"method":"login"` request that comes right after a client-side close (`Closing *:0 (Client…)`), or the first `login` in the log history.
- **Reconnect (ignored):** a `login` that follows `Closing … (Disconnected by gateway)`. This is the same session moving to a different gateway node.
- **Token refresh (ignored):** `update-tokens` calls don't extend the session.
- **Session length:** learned from past sessions as the time from sign-in to the first `token-renewal-notification`, plus `timeLeft` (300 s). Defaults to 24 h when there's no history. All 7 sessions from 5–11 Oct 2026 measured exactly 24 h.
- **Live fallback:** an unexpected `token-renewal-notification` means expiry is `timeLeft` seconds away, whatever the timing model predicted.

These are observations from Appgate client 6.5.3 talking to gateway 6.5.6. They aren't documented anywhere, so the parser has to fail loudly rather than guess.

## Architecture: one Swift package
| Target | What it does |
|---|---|
| `GatekeeprCore` | Reads the logs (including gzip), splits them into sessions, learns the session length, computes expiry. No UI, fully unit-tested |
| `gatekeepr` (CLI) | swift-argument-parser |
| `Gatekeepr.app` | SwiftUI `MenuBarExtra`, watches the log for changes (no polling), sends native notifications |

Minimum macOS 13 (needed for `MenuBarExtra`).

## Milestone 1: core + CLI
- `gatekeepr` prints sign-in time, expiry, time left, and how many sessions the length was learned from
- `gatekeepr --json` gives machine-readable output
- `gatekeepr --short` prints one line like `6h08m`, for statuslines
- `gatekeepr history` lists past sessions with their measured lengths
- `--warn <duration>` sets the warning threshold (default 30m)
- `--log-dir <path>` overrides the log location (used by tests and odd installs)
- Exit codes: `0` ok · `1` within warn window · `2` expired / not signed in · `3` log unreadable or unparseable
- Tests run against **sanitized** fixtures: a normal day, a reconnect mid-session, an expiry, gzip rotation, an empty log, an unknown format

## Milestone 2: menu bar app
- Icon with the time left, which changes colour inside the warn window and when expired
- Dropdown: sign-in time, expiry, session history, and an "Open Appgate" button
- Native notification at the warn threshold (configurable), sent once per session
- Launch at login via `SMAppService`
- Updates instantly when you sign in again, using a file watch on `driver.log`

## Distribution
- **Homebrew tap** (`brew install <user>/tap/gatekeepr`): the formula covers the CLI and a cask covers the app
- **GitHub Releases:** a notarized `.app` zip and a universal CLI binary
- **Not on the App Store:** a sandboxed app can't read `/var/log/appgate`
- CI on GitHub Actions: build + test on every PR, and tags build, sign, notarize and release

## Out of scope
- Auto-renewing the session (Appgate sign-in needs SSO with you present)
- Windows / Linux log paths (the parser keeps paths pluggable, but only macOS ships)
- Lucidos trigger and Claude Code statusline integration. These are consumers of `--json` / `--short` and get set up separately

## Public-repo hygiene
- Never commit raw logs. Fixtures must swap gateway hostnames (`*.sdp.m10s.io`), gateway IPs, tunnel IPs, entitlement IDs and request IDs for fake values
- Ship a `scripts/sanitize-log` tool so bug reporters can share logs safely
- The README makes clear this is an unofficial tool, not affiliated with Appgate, and works from observed log behaviour

## Open questions
- Which GitHub account owns it (personal vs `waadrarii`)?
- Signing identity for notarization: personal Developer ID or Waadrarii's?
