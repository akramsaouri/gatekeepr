# gatekeepr

Know when your Appgate SDP session on macOS is about to expire, from the
command line.

> **Unofficial.** gatekeepr is not affiliated with, endorsed by or supported by
> Appgate. It works from observed `driver.log` behaviour, not a documented API,
> so a future Appgate release can break it. When the logs stop looking the way
> gatekeepr expects, it says so and exits with code 3 rather than guessing.

Appgate doesn't show when your session ends. You get a 5-minute warning and
then everything behind the VPN stops working. gatekeepr reads the driver logs
in `/var/log/appgate`, which any user can read, and tells you when that will
happen. It needs no root and makes no network calls.

gatekeepr is a single command-line tool. Up to v0.2.1 there was also a menu
bar app; it was removed in v0.3.0, and
[v0.2.1](https://github.com/akramsaouri/gatekeepr/releases/tag/v0.2.1) is the
last release that has it. See [docs/SCOPE.md](docs/SCOPE.md).

## Install

gatekeepr needs macOS 13 or later, on Apple silicon or Intel. It's installed
from [GitHub Releases](https://github.com/akramsaouri/gatekeepr/releases/latest),
or built from source. Every release has:

| File | What it is |
|---|---|
| `gatekeepr-<version>-macos-universal.tar.gz` | The CLI (arm64 and x86_64 in one binary), with the licence and this README |
| `SHA256SUMS` | Its SHA-256 checksum |

The binary is ad-hoc signed and not notarized.

```sh
version=0.3.0
base=https://github.com/akramsaouri/gatekeepr/releases/download/v$version
curl -fLO "$base/gatekeepr-$version-macos-universal.tar.gz"
curl -fLO "$base/SHA256SUMS"
shasum -a 256 -c --ignore-missing SHA256SUMS
tar -xzf "gatekeepr-$version-macos-universal.tar.gz"
sudo install "gatekeepr-$version-macos-universal/gatekeepr" /usr/local/bin/
gatekeepr --version
```

`shasum` should print `gatekeepr-<version>-macos-universal.tar.gz: OK`.
Anything else means a corrupted or tampered download: delete it and don't run
it. Or put `gatekeepr` anywhere else on your `PATH`.

With the [GitHub CLI](https://cli.github.com), the two downloads are
`gh release download --repo akramsaouri/gatekeepr --pattern 'gatekeepr-*' --pattern SHA256SUMS`.

`curl` and `gh` don't mark what they download as quarantined, so the binary
runs straight away. If you download the tarball in a browser instead, macOS
quarantines it, carries that over to the unpacked binary, and refuses to run
it. Clear the flag before you install it:

```sh
xattr -d com.apple.quarantine "gatekeepr-$version-macos-universal/gatekeepr"
```

### Build from source

You need Go 1.26 or later. Either install it straight from the module:

```sh
go install github.com/akramsaouri/gatekeepr@latest
```

which puts `gatekeepr` in `$(go env GOPATH)/bin`, or clone and build:

```sh
git clone https://github.com/akramsaouri/gatekeepr.git
cd gatekeepr
go build
sudo install gatekeepr /usr/local/bin/
```

gatekeepr only uses Go's standard library.

## Usage

```console
$ gatekeepr
Appgate session active
  Signed in  Sun 11 Oct 01:24
  Expires    Mon 12 Oct 01:24
  Time left  6h08m
  Length     24h00m, the median of 17 measured sessions
```

Times are in your local time zone.

| Command | What it does |
|---|---|
| `gatekeepr` | Sign-in time, expiry, time left, and how many sessions the length was learned from |
| `gatekeepr --short` | One line like `6h08m` (or `expired`, `signed out`, `no session`), for statuslines |
| `gatekeepr --json` | Machine-readable status, see [JSON](#json) |
| `gatekeepr history` | Past sessions with their measured lengths (`--json` works here too) |
| `--warn <duration>` | Warning threshold, default `30m`. Accepts `45s`, `30m`, `2h`, `1h30m` |
| `--log-dir <path>` | Read logs from somewhere other than `/var/log/appgate` |

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Signed in, more than the warn threshold left |
| 1 | Signed in, within the warn threshold |
| 2 | Expired, or not signed in |
| 3 | Logs unreadable, or in a format gatekeepr doesn't recognise |
| 64 | Wrong command line (unknown option, bad `--warn`, `--json` with `--short`) |

So a script can do `gatekeepr --short --warn 1h || notify "Appgate session ending"`.

### JSON

```console
$ gatekeepr --json
{
  "exitCode" : 0,
  "expiresAt" : "2026-10-12T01:24:40+02:00",
  "expirySource" : "sessionLength",
  "now" : "2026-10-11T19:16:00+02:00",
  "schemaVersion" : 1,
  "secondsLeft" : 22120,
  "sessionLengthLearnedFrom" : 17,
  "sessionLengthSeconds" : 86399,
  "sessionLengthSource" : "median",
  "sessionStart" : "2026-10-11T01:24:41+02:00",
  "sessionStartKind" : "signIn",
  "state" : "active",
  "timeLeft" : "6h08m",
  "warnThresholdSeconds" : 1800
}
```

The JSON output is a stable contract, documented field by field, state by
state, in **[docs/JSON.md](docs/JSON.md)**, along with `history --json`, the
error object and the exit codes. In short: `state` is one of `active`,
`expiringSoon`, `expired`, `signedOut` or `noSession`, times are ISO 8601 with
your UTC offset, and fields that don't apply are left out. On errors you get
`{"state": "error", "exitCode": 3, "error": "...", "schemaVersion": 1}`. Any
change to the schema bumps `schemaVersion`.

### History

```console
$ gatekeepr history
Start             How      End               Outcome      Length  Reconnects
Thu 10 Sep 09:36  sign-in  Fri 11 Sep 09:31  renewed      24h00m  4
Fri 11 Sep 09:31  renewal  Sat 12 Sep 09:31  expired      24h00m  0
...
Tue 6 Oct 09:52   sign-in  Wed 7 Oct 08:12   interrupted  -       0
Wed 7 Oct 08:18   sign-in  Thu 8 Oct 08:18   expired      24h00m  0
Sun 11 Oct 01:24  sign-in  -                 active       -       1
```

## How it works

There is no API for any of this. Everything comes from `driver.log` and the
rotated `driver-YYYY-MM-DD.log.gz` files, read oldest first. Each line looks
like `[2026-10-10T23:24:41.741Z] Info : <message>`, in UTC.

- **Sign-in.** The client sends a `login` to each site (AWS and GCP, say) within
  a second or two; that's one sign-in. A login counts as a sign-in when the
  previous session is over: the client closed its control connection
  (`Closing *:0 (Client closed control connection)`, or another port such as
  `*:52253`), the client opened a new control connection, or the driver
  restarted (after a reboot, for example). The first login in the log history
  counts too.
- **Reconnects don't count.** When a gateway drops the tunnel
  (`Disconnected by gateway`, `Dead connection detected`, an IP address change),
  the client reconnects and sends a fresh `login`. That's the same session.
- **Token refreshes don't count.** Periodic `update-tokens` calls, and the
  `deploy` + `update-tokens` that follows a `token-revocation`, don't extend
  the session.
- **Renewing from the warning does count.** If you renew while Appgate's
  countdown is running, the client sends a `deploy` with no close and no login,
  and you get a full new session from that moment.
- **Session length** is learned from your own history: for each session, the
  time from sign-in to the first `token-renewal-notification`, plus that
  notification's `timeLeft` (300 s). gatekeepr uses the median, and 24 hours
  when there's nothing to learn from yet. Observed so far: 24 hours, every time.
- **Live fallback.** Once a renewal notification shows up in the current
  session, expiry is that notification's time plus its `timeLeft`, whatever the
  learned length says.
- **Fail loudly.** A line that doesn't match the log format, or a login,
  renewal notification or close with an unexpected shape, stops gatekeepr with
  exit code 3 and the file and line number. Everything else (routes, DNS,
  status JSON, `All sites connected in 2114ms`, `netstat` output and its
  `Expire` column) is ignored.

These rules come from Appgate client 6.5.3 talking to gateway 6.5.6, on one
machine. Logs from other setups are the main thing left to check them against:
see the next section.

## Reporting a parse failure

If gatekeepr exits with 3 on your logs and says a line "doesn't match any known
Appgate log format" or has an unexpected shape, the rules need to learn your
Appgate version's logs. Please send the offending excerpt:

1. Note the file and line from the message, like
   `driver-2026-10-10.log.gz:1234`.
2. Copy that line and a few dozen lines around it, and run them through the
   sanitizer, which needs only Python 3:

   ```sh
   gzcat /var/log/appgate/driver-2026-10-10.log.gz | sed -n '1200,1270p' > excerpt.log
   # for the live log: sed -n '1200,1270p' /var/log/appgate/driver.log > excerpt.log
   scripts/sanitize-log excerpt.log > excerpt.sanitized.log
   scripts/sanitize-log --check excerpt.sanitized.log
   ```

   `--check` reports anything that still looks like a real address or token.
3. Read `excerpt.sanitized.log` yourself before sharing it, then
   [open an issue](https://github.com/akramsaouri/gatekeepr/issues/new) with
   the excerpt, the full error message, `gatekeepr --version`, and your
   Appgate client version. The driver logs it whenever it starts:
   `gzcat -f /var/log/appgate/driver*.log* | grep loop_init | tail -1`.

`scripts/sanitize-log` is in this repository, not in the release tarball:
download it from
[GitHub](https://raw.githubusercontent.com/akramsaouri/gatekeepr/main/scripts/sanitize-log),
or clone the repository.

## Sharing logs

Raw Appgate logs contain gateway hostnames, IP addresses, MAC addresses, device
IDs and your e-mail address. Before attaching a log to an issue, run it through
the sanitizer, which swaps all of those (and anything token-like) for stable
fake values:

```sh
scripts/sanitize-log /var/log/appgate/driver.log > driver.sanitized.log
scripts/sanitize-log --check driver.sanitized.log   # reports anything that still looks real
```

It reads `.gz` files too. Read the output before you share it anyway.

## Development

```sh
go vet ./...
go test -race ./...
```

| Package | What it is |
|---|---|
| `internal/core` | Reads the logs, splits them into sessions, learns the length, computes expiry. Also the status wording and the `--json` reports |
| `internal/cli` | The command line: arguments, help, and the output layout |
| `.` (`main.go`) | Runs `internal/cli` |

Tests run against sanitized excerpts of real logs in
[`testdata/fixtures`](testdata/fixtures). The golden files in
[`testdata/golden`](testdata/golden) pin what gatekeepr prints and exits with
for every state, history, errors, help and usage errors. They were first
captured from the Swift version that gatekeepr v0.2.x was written in, and the
Go version matches them byte for byte (see the README there). After an
intended change to the output, run `go test -run TestGolden -update` and
review the diff.

Never commit raw logs: `.gitignore` blocks `*.log` and `*.log.gz` outside the
fixtures directory, and CI runs `scripts/sanitize-log --check` over the fixtures.

CI runs vet and the tests with the oldest Go that `go.mod` allows and with the
Go releases are built with (`.go-version`), and builds and checks the release
files on every pull request.

### Releasing

Releases are built by GitHub Actions
([`release.yml`](.github/workflows/release.yml)) when a `v*` tag is pushed:

1. Set the version in `internal/cli/cli.go` (`const Version`). It's the only
   place it lives.
2. Optionally, write `.github/release-notes/v<version>.md`; it goes at the top
   of the release notes.
3. Merge that to `main`, then tag the merge commit and push the tag:
   `git tag v0.3.1 && git push origin v0.3.1`.

The workflow runs vet, the tests and the fixture check with the Go in
`.go-version`, builds the universal binary with `scripts/build-release` (one
`go build` per architecture, merged with `lipo`, signed ad hoc with the
hardened runtime), and runs `scripts/check-release`, which fails unless the
tag, `internal/cli/cli.go` and `gatekeepr --version` on both slices agree, the
binary has arm64 and x86_64 slices (`lipo -archs`), and it's signed. Only then
does it publish the release, with notes listing the commits since the previous
tag. It uploads to a draft first, so a failed run never leaves a half-published
release.

CI runs the same two scripts on every pull request, so you can try them
locally too (on macOS):

```sh
scripts/build-release          # writes dist/
scripts/check-release dist v0.3.1
```
