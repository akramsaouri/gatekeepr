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
- **Menu bar text** is exactly `gatekeepr --short` (`6h08m`, `expired`, `signed out`, `no session`, `error`), next to a ring that drains as the session runs out (since 0.2.1, see below; it started out as SF Symbols). Normal: a monochrome template image. Warn window: orange ring and text. Expired: a red ✕ in a red ring. Signed out / no session: a dash in the empty track. Log unreadable or unparseable (the CLI's exit 3): red triangle and `error`, with the reason in the menu, never an old or guessed answer
- **Menu:** the same heading and rows as `gatekeepr` (sign-in, expiry, time left, length and how many sessions it was learned from), the last 10 sessions from the `history` logic, Open Appgate (bundle id `com.appgate.sdp`, then `Appgate SDP.app` / `AppGate SDP.app` in the Applications folders), Warn Before Expiry (5m, 10m, 15m, 30m, 45m, 1h, 2h; default 30m; persisted), Launch at Login (`SMAppService.mainApp`), Quit
- **Notifications** (`UNUserNotificationCenter`): a warning when the session enters the warn window, once per session; and an expiry notice, once per session, only if the expiry is under 15 minutes old (so launching or waking the next morning doesn't announce it). A session is identified by its start time; the last one notified for each kind is persisted, so relaunching doesn't repeat them. A new session withdraws the old notifications. Clicking one opens Appgate. The app sets `NSUserNotificationAlertStyle = alert`, so warnings stay on screen until dismissed
- **File watch:** kqueue (DispatchSource) on `/var/log/appgate` and on `driver.log`. The directory source catches rotation (a new `driver.log` inode, `.gz` files appearing) and re-opens the file source; the file source catches appends and truncation. Other files there (`driver.status`) are ignored. If the directory is missing, the parent is watched until it appears. Bursts are coalesced (250 ms). No polling; the only timer ticks the countdown, firing just after the displayed minute changes, and the app re-checks on wake
- **Not sandboxed:** it has to read `/var/log/appgate`
- **Packaging:** `scripts/build-app` builds release, assembles `Gatekeepr.app` (LSUIElement, bundle id `io.github.akramsaouri.gatekeepr`, version from `Gatekeepr.version`) and signs it ad hoc with the hardened runtime. CI runs it on every PR

## Milestone 3: GitHub Releases
Distribution through GitHub Releases only; Homebrew is deferred (see Distribution).

Done. How it came out:
- **Trigger:** pushing a `v*` tag runs `.github/workflows/release.yml` on `macos-latest`: the full test suite, `scripts/sanitize-log --check` over the fixtures, `scripts/build-release`, `scripts/check-release dist <tag>`, then the release
- **Assets:** `Gatekeepr-<version>.zip` (the app, zipped with `ditto -c -k --norsrc --keepParent`), `gatekeepr-<version>-macos-universal.tar.gz` (the CLI in a `gatekeepr-<version>-macos-universal/` folder with `LICENSE` and `README.md`) and `SHA256SUMS`
- **Universal:** both binaries are built with `swift build --arch arm64 --arch x86_64` (`scripts/build-app --universal` for the app) and checked with `lipo -archs`. Minimum macOS 13 on both slices
- **Signing:** both ad hoc with the hardened runtime, not notarized. `GATEKEEPR_SIGN_IDENTITY` and the `TODO(signing)` / `TODO(notarization)` hook in `scripts/build-app` stay for later
- **One version:** `Gatekeepr.version` in `Sources/GatekeeprCore/Version.swift` is the only copy. `gatekeepr --version` prints it and `scripts/build-app` writes it into `CFBundleShortVersionString` and `CFBundleVersion`. `scripts/check-release` fails the release unless the tag is `v` + that version and the built CLI (both slices; x86_64 under Rosetta), the plist and the source all agree
- **Checks on the shipped files:** `scripts/check-release` unpacks the archives the way a user would (with `unzip`, the strictest) and checks the checksums, both architectures, both signatures (valid, ad hoc, hardened runtime), the bundle id and `LSUIElement`. CI runs `build-release` and `check-release` on every PR, so the packaging is tested before a tag ever is
- **Why `--norsrc`:** plain `ditto -c -k` stores extended attributes (`com.apple.provenance` on every built file) as `._` entries next to each file. Finder and `ditto -x` fold them back in, but `unzip` leaves them inside the bundle, which breaks its seal ("a sealed resource is missing or invalid")
- **Release notes:** the commits since the previous `v*` tag (all of them for the first release), under a fixed "Not notarized, by choice" note that points to the README's Install section, plus the `shasum` command and a compare link
- **No half-published releases:** the release is created as a draft with every asset attached, then published. If any step fails, a draft left by the run is deleted (a published release never is). A failed run is fixed on `main`, and the tag deleted and pushed again
- **Quarantine:** `curl` and `gh release download` don't quarantine downloads; browsers do, and `tar`, `ditto` and `unzip` all carry the flag over to the extracted app or binary. So a browser-downloaded CLI also needs `xattr -d com.apple.quarantine` (the README covers both)

## 0.2.1: app icon and draining ring
- **App icon:** a frosted-glass G on a near-black body, on the macOS icon grid (an 824 × 824 continuous-corner body on a 1024 canvas, with a soft drop shadow). `assets/icon/icon.svg` covers 128 px and up; `assets/icon/icon-small.svg` is a flat silver G for 16 and 32 px (@1x and @2x), drawn on the 16-pixel grid so the bar and stem land on whole pixels. `scripts/make-icon` renders both with `rsvg-convert`, builds `assets/icon/AppIcon.icns` with `iconutil` and writes `docs/icon-contact-sheet.png` from the images it reads back out of the `.icns`
- **Committed `.icns`:** GitHub's macOS runners don't have `rsvg-convert`, so the `.icns` and the contact sheet are committed next to their sources and `scripts/build-app` only copies the `.icns`. Releases don't depend on Homebrew, and the shipped icon doesn't change with whatever librsvg version a runner happens to get
- **In the bundle:** `scripts/build-app` copies the icon to `Contents/Resources/AppIcon.icns` and sets `CFBundleIconFile` and `CFBundleIconName`. `scripts/check-release` fails unless the unpacked app has it, both keys name it, and it holds every size from 16 to 1024 px. `LSUIElement` stays on: still no Dock icon
- **Draining ring:** the menu bar glyph is drawn in code. Its progress is the time left over the learned session length, clamped to 0…1: full after sign-in, emptying clockwise from 12 o'clock over a faint full-circle track, redrawn on the existing once-a-minute countdown tick. With no usable session length, only the track is drawn. `StatusGlyph` (GatekeeprMenuBar, unit-tested) maps the tone and progress to a shape and colour; `StatusItemImage` (GatekeeprApp) draws it as a 15 pt ring with a 2 pt stroke, the box an SF Symbol circle gets at the 13 pt menu bar font, centred on the cap height with its edges on whole pixels at @1x and @2x. Errors keep the red SF Symbol triangle
- **Pictures:** `docs/icon-contact-sheet.png` (from `scripts/make-icon`) and `docs/menu-bar-states.png` (rendered by `GatekeeprAppTests` when `GATEKEEPR_STATUS_STRIP` is set)

## Distribution
**Unsigned by choice (decided 2026-10-12):** `Gatekeepr.app` is ad-hoc signed and not notarized. The cost is accepted: a downloaded copy needs a one-time **Open Anyway** in System Settings › Privacy & Security (the README walks through it). `scripts/build-app` keeps its `TODO(signing)` / `TODO(notarization)` hook (`GATEKEEPR_SIGN_IDENTITY`) in case this is revisited.

- **GitHub Releases:** done in Milestone 3. An ad-hoc-signed `.app` zip (not notarized), a universal CLI tarball and `SHA256SUMS`
- **Homebrew tap** (`brew install <user>/tap/gatekeepr`): **deferred** (decided 2026-10-12), not part of Milestone 3. When it happens, the formula covers the CLI and a cask covers the app, both pointing at the release assets and their `SHA256SUMS`
- **Not on the App Store:** a sandboxed app can't read `/var/log/appgate`
- CI on GitHub Actions: build, test and the release packaging on every PR; tags build, ad-hoc sign and release

## Out of scope
- Auto-renewing the session (Appgate sign-in needs SSO with you present)
- Windows / Linux log paths (the parser keeps paths pluggable, but only macOS ships)
- Lucidos trigger and Claude Code statusline integration. These are consumers of `--json` / `--short` and get set up separately

## Public-repo hygiene
- Never commit raw logs. Fixtures must swap gateway hostnames (`*.sdp.m10s.io`), gateway IPs, tunnel IPs, entitlement IDs and request IDs for fake values
- Ship a `scripts/sanitize-log` tool so bug reporters can share logs safely
- The README makes clear this is an unofficial tool, not affiliated with Appgate, and works from observed log behaviour

## Open questions
None. Settled 2026-10-12: the repo lives on the personal account (`akramsaouri`), so the bundle id stays `io.github.akramsaouri.gatekeepr`. No Developer ID signing or notarization (see Distribution).
