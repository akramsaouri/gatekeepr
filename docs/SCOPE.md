# gatekeepr: scope

Shows when your Appgate SDP session on macOS will expire, as a CLI and a menu bar app. Public GitHub repo, MIT licence.

## Why
Claude Code goes through Vend's gateway, which sits behind Appgate. Appgate doesn't show when the session expires, so Claude just stops working, and you only get a 5-minute warning before it does.

## How detection works
There's no API for this. gatekeepr works it out from `/var/log/appgate/driver.log` and the rotated `driver-*.log.gz` files, which any user can read. It needs no root and makes no network calls.

- **Real sign-in:** a `"method":"login"` request that comes right after a client-side close (`Closing *:<port> (Client…)` or `Client closed control connection`), or the first `login` in the log history. Also the first login after the driver restarts (`Starting event loop`, e.g. after a reboot on 7 Oct 2026 there was no client close before the next sign-in) or after a new `Got control connection`.
- **Reconnect (ignored):** a `login` that follows `Closing … (Disconnected by gateway)`, `Dead connection detected`, an IP address change or a connect timeout. This is the same session moving to a different gateway node.
- **Token refresh (ignored):** `update-tokens` calls don't extend the session, nor does the `deploy` + `update-tokens` that follows a `token-revocation`.
- **Renewal in place:** a `deploy` (followed by `update-tokens`, with no close or login) while `token-renewal-notification`s are counting down is the user renewing from the warning. It starts a new full-length session. Seen three times in Sept 2026: each time the next notification came exactly 23h55m after the `deploy`.
- **Session length:** learned from past sessions as the time from sign-in to the first `token-renewal-notification`, plus `timeLeft` (300 s). Defaults to 24 h when there's no history. All 7 sessions from 5–11 Oct 2026 measured exactly 24 h, and so did all 17 measurable sessions from 10 Sept to 11 Oct.
- **Live fallback:** an unexpected `token-renewal-notification` means expiry is `timeLeft` seconds away, whatever the timing model predicted.

These are observations from Appgate client 6.5.3 talking to gateway 6.5.6. They aren't documented anywhere, so the parser has to fail loudly rather than guess.

## Architecture: one Swift package
| Target | What it does |
|---|---|
| `GatekeeprCore` | Reads the logs (including gzip), splits them into sessions, learns the session length, computes expiry. Also the wording the CLI and app share (`StatusText`). No UI, fully unit-tested |
| `gatekeepr` (CLI) | swift-argument-parser |
| `GatekeeprMenuBar` | The app's logic without UI: state mapping, notification bookkeeping, settings, the log watcher. Unit-tested |
| `GatekeeprApp` → `Gatekeepr.app` | SwiftUI `MenuBarExtra`, watches the log for changes (no polling), sends native notifications. `scripts/build-app` makes the bundle. Not named `Gatekeepr` because on a case-insensitive disk it would collide with the `gatekeepr` CLI in `.build/` |

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

Done. How it came out:
- **Menu bar text** is exactly `gatekeepr --short` (`6h08m`, `expired`, `signed out`, `no session`, `error`). Normal: monochrome clock. Warn window: orange hourglass and text. Expired: red. Signed out / no session: monochrome ✕. Log unreadable or unparseable (the CLI's exit 3): red triangle and `error`, with the reason in the menu, never an old or guessed answer
- **Menu:** the same heading and rows as `gatekeepr` (sign-in, expiry, time left, length and how many sessions it was learned from), the last 10 sessions from the `history` logic, Open Appgate (bundle id `com.appgate.sdp`, then `Appgate SDP.app` / `AppGate SDP.app` in the Applications folders), Warn Before Expiry (5m, 10m, 15m, 30m, 45m, 1h, 2h; default 30m; persisted), Launch at Login (`SMAppService.mainApp`), Quit
- **Notifications** (`UNUserNotificationCenter`): a warning when the session enters the warn window, once per session; and an expiry notice, once per session, only if the expiry is under 15 minutes old (so launching or waking the next morning doesn't announce it). A session is identified by its start time; the last one notified for each kind is persisted, so relaunching doesn't repeat them. A new session withdraws the old notifications. Clicking one opens Appgate. The app sets `NSUserNotificationAlertStyle = alert`, so warnings stay on screen until dismissed
- **File watch:** kqueue (DispatchSource) on `/var/log/appgate` and on `driver.log`. The directory source catches rotation (a new `driver.log` inode, `.gz` files appearing) and re-opens the file source; the file source catches appends and truncation. Other files there (`driver.status`) are ignored. If the directory is missing, the parent is watched until it appears. Bursts are coalesced (250 ms). No polling; the only timer ticks the countdown, firing just after the displayed minute changes, and the app re-checks on wake
- **Not sandboxed:** it has to read `/var/log/appgate`
- **Packaging:** `scripts/build-app` builds release, assembles `Gatekeepr.app` (LSUIElement, bundle id `io.github.akramsaouri.gatekeepr`, version from `Gatekeepr.version`) and signs it ad hoc with the hardened runtime. CI runs it on every PR

## Distribution
Not started. `Gatekeepr.app` is ad-hoc signed for now because there's no Developer ID certificate yet; `scripts/build-app` has a `TODO(signing)` / `TODO(notarization)` hook (`GATEKEEPR_SIGN_IDENTITY`) for when there is.

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
- Which GitHub account owns it (personal vs `waadrarii`)? The app's bundle id, `io.github.akramsaouri.gatekeepr`, assumes the personal account. Changing it later resets the app's settings and notification permission
- Signing identity for notarization: personal Developer ID or Waadrarii's?
