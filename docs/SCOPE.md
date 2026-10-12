# gatekeepr: scope

A command-line tool that shows when your Appgate SDP session on macOS will expire. Public GitHub repo, MIT licence.

## Why
Claude Code goes through Vend's gateway, which sits behind Appgate. Appgate doesn't show when the session expires, so Claude just stops working, and you only get a 5-minute warning before it does.

## What it is
- **A CLI, and only a CLI.** `gatekeepr` prints the sign-in time, expiry, time left and how the session length was learned; `--short` prints one line for statuslines; `--json` prints a versioned, documented object ([JSON.md](JSON.md)); `history` lists past sessions. Exit codes: `0` ok · `1` within the warn window · `2` expired / not signed in · `3` logs unreadable or unparseable · `64` wrong command line.
- **The menu bar app was removed in v0.3.0** (decided 2026-10-12: not needed). v0.2.x releases still have it, and stay up: [v0.2.1](https://github.com/akramsaouri/gatekeepr/releases/tag/v0.2.1) is the last one with `Gatekeepr.app`.
- **Written in Go since v0.3.0**, standard library only. v0.1–v0.2 were Swift. The port was checked case by case against the Swift CLI's output (see [Parity with the Swift version](#parity-with-the-swift-version)).
- **Consumers.** A Lucidos plugin will read `gatekeepr --json` later; that's a separate project. Statusline scripts use `--short` or `--json`. `--json` is the contract for all of them: any schema change bumps `schemaVersion`.

## How detection works
There's no API for this. gatekeepr works it out from `/var/log/appgate/driver.log` and the rotated `driver-*.log.gz` files, which any user can read. It needs no root and makes no network calls.

- **Real sign-in:** a `"method":"login"` request that comes right after a client-side close (`Closing *:<port> (Client…)`, where the port is `0` or a real one like `52253`, or `Client closed control connection`), or the first `login` in the log history. Also the first login after the driver restarts (`Starting event loop` / `Stopping event loop`, e.g. after a reboot on 7 Oct 2026 there was no client close before the next sign-in) or after a new `Got control connection`.
- **Reconnect (ignored):** a `login` that follows `Closing … (Disconnected by gateway)`, `Dead connection detected`, an IP address change or a connect timeout. This is the same session moving to a different gateway node.
- **Token refresh (ignored):** `update-tokens` calls don't extend the session, nor does the `deploy` + `update-tokens` that follows a `token-revocation`.
- **Renewal in place:** a `deploy` (followed by `update-tokens`, with no close or login) while `token-renewal-notification`s are counting down is the user renewing from the warning. It starts a new full-length session. Seen three times in Sept 2026: each time the next notification came exactly 23h55m after the `deploy`.
- **Session length:** learned from past sessions as the time from sign-in to the first `token-renewal-notification`, plus `timeLeft` (300 s); the median over all measurable sessions. Defaults to 24 h when there's no history. All 7 sessions from 5–11 Oct 2026 measured exactly 24 h, and so did all 17 measurable sessions from 10 Sept to 11 Oct.
- **Live fallback:** an unexpected `token-renewal-notification` means expiry is `timeLeft` seconds away, whatever the timing model predicted.
- **Fail loudly:** a line that doesn't match the log format, or a login, renewal notice or close with an unexpected shape, exits 3 with the file and line. Never a guess.

These are observations from Appgate client 6.5.3 talking to gateway 6.5.6, on one machine. They aren't documented anywhere. Logs from other machines and Appgate versions are the main validation still to do; the README's "Reporting a parse failure" asks for sanitized excerpts.

## Layout
| Path | What it does |
|---|---|
| `internal/core` | Reads the logs (including gzip), splits them into sessions, learns the session length, computes expiry, words the status, builds the `--json` reports. Unit-tested against sanitized fixtures |
| `internal/cli` | Arguments, help and output layout |
| `main.go` | Runs `internal/cli`; `go install github.com/akramsaouri/gatekeepr@latest` builds it |
| `testdata/fixtures` | Sanitized, trimmed excerpts of real `/var/log/appgate` directories |
| `testdata/golden` | Every state, history, error, help and usage error, pinned byte for byte |
| `scripts/sanitize-log` | Python 3 sanitizer for sharing logs; CI runs `--check` over the fixtures |
| `scripts/build-release`, `scripts/check-release` | Build and check the release tarball |

## Parity with the Swift version
Before the Swift code was deleted, the Swift CLI (v0.2.1, with a capture-only clock override) recorded 268 cases into `testdata/golden`: every state in default, `--short` and `--json` output, history, errors, other time zones, help at several terminal widths, and swift-argument-parser's usage errors and their precedence. The Go version matches all text, help and usage-error output and every exit code byte for byte; its JSON is the Swift JSON plus `schemaVersion` and `sessionLengthSource`, which the golden test checks. On top of that, both builds were run side by side over a month of real logs (8,683 cases: hourly, minute by minute around every session's start and expiry, and at exact millisecond boundaries) with no differences, and on hand-made broken log directories.

Deliberate or unavoidable differences, all in error paths:
- A `token-renewal-notification` whose `timeLeft` is a JSON boolean exits 3. Swift read `true` as 1 second (Foundation bridges JSON booleans to numbers), which the strict-parsing rule never meant to allow.
- For structurally corrupt deflate data in a `.gz` file, the detail in parentheses is `invalid compressed data` instead of zlib's specific reason (`invalid block type`, …). Go's `compress/flate` doesn't say why. The rest of the message and the exit code are the same.
- Under `/dev` (devfs), a bad `--log-dir` is worded with the plain errno text in places where Foundation used its own sentence. Paths on normal volumes match.
- `--warn` values beyond Go's ~292-year duration limit are rejected as invalid instead of accepted.
- swift-argument-parser's hidden built-ins `--generate-completion-script` and `--experimental-dump-help` are gone. Neither was documented.

## Distribution
- **GitHub Releases only.** A release has `gatekeepr-<version>-macos-universal.tar.gz` (a `gatekeepr-<version>-macos-universal/` folder with the binary, `LICENSE` and `README.md`) and `SHA256SUMS`. The binary is universal (two `go build`s, darwin/arm64 and darwin/amd64, merged with `lipo`), minimum macOS 13, and ad-hoc signed with the hardened runtime. `scripts/check-release` checks the checksums, the archive's contents, `lipo -archs`, the signature and `--version` on both slices before anything is published.
- **macOS only.** No Linux or Windows builds: the log rules are macOS observations.
- **Not notarized, by choice** (decided 2026-10-12). `curl` and `gh release download` don't quarantine downloads, so the binary runs as is; a browser download needs `xattr -d com.apple.quarantine` (the README covers it). `GATEKEEPR_SIGN_IDENTITY` in `scripts/build-release` is the hook if a Developer ID ever comes.
- **Homebrew: not planned for now.**
- **Go versions:** `go.mod` says the oldest Go that builds it (1.26, the oldest Go release still supported); `.go-version` pins the Go releases are built with. CI tests both.
- **Releases** are cut by pushing a `v*` tag: `.github/workflows/release.yml` tests, builds, checks, uploads to a draft and only then publishes. If a run fails, the tag and release are deleted before retrying.

## Out of scope
- The menu bar app (removed in v0.3.0; see above)
- The Lucidos plugin itself (a consumer of `--json`, built separately)
- Auto-renewing the session (Appgate sign-in needs SSO with you present)
- Windows / Linux log paths
- Homebrew

## Public-repo hygiene
- Never commit raw logs. Fixtures swap gateway hostnames, gateway IPs, tunnel IPs, entitlement IDs and request IDs for fake values, and CI runs `scripts/sanitize-log --check` on them
- `scripts/sanitize-log` lets bug reporters share logs safely
- The README makes clear this is an unofficial tool, not affiliated with Appgate, and works from observed log behaviour

## History
- **v0.1:** core library and CLI (Swift)
- **v0.2.0:** menu bar app, GitHub Releases
- **v0.2.1:** app icon and a draining menu bar ring
- **v0.3.0:** CLI only, rewritten in Go; `--json` versioned and documented
