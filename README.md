# gatekeepr

Know when your Appgate SDP session on macOS is about to expire, as a CLI and a
menu bar app.

> **Unofficial.** gatekeepr is not affiliated with, endorsed by or supported by
> Appgate. It works from observed `driver.log` behaviour, not a documented API,
> so a future Appgate release can break it. When the logs stop looking the way
> gatekeepr expects, it says so and exits with code 3 rather than guessing.

Appgate doesn't show when your session ends. You get a 5-minute warning and
then everything behind the VPN stops working. gatekeepr reads the driver logs
in `/var/log/appgate`, which any user can read, and tells you when that will
happen. It needs no root and makes no network calls.

Status: Milestone 2 (menu bar app), on top of Milestone 1 (core library + CLI).
See [docs/SCOPE.md](docs/SCOPE.md).

## Install from source

You need macOS 13 or later and Swift 5.9 or later (Xcode 15+, or the Command
Line Tools).

```sh
git clone https://github.com/akramsaouri/gatekeepr.git
cd gatekeepr
swift build -c release
sudo install .build/release/gatekeepr /usr/local/bin/
```

Or put `.build/release/gatekeepr` anywhere else on your `PATH`.

For the menu bar app, see [Menu bar app](#menu-bar-app).

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
| `gatekeepr --json` | Machine-readable status |
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

So a script can do `gatekeepr --short --warn 1h || notify "Appgate session ending"`.

### JSON

```console
$ gatekeepr --json
{
  "exitCode" : 0,
  "expiresAt" : "2026-10-12T01:24:40+02:00",
  "expirySource" : "sessionLength",
  "now" : "2026-10-11T19:16:00+02:00",
  "secondsLeft" : 22120,
  "sessionLengthLearnedFrom" : 17,
  "sessionLengthSeconds" : 86399,
  "sessionStart" : "2026-10-11T01:24:41+02:00",
  "sessionStartKind" : "signIn",
  "state" : "active",
  "timeLeft" : "6h08m",
  "warnThresholdSeconds" : 1800
}
```

`state` is one of `active`, `expiringSoon`, `expired`, `signedOut` or
`noSession`. `expirySource` is `sessionLength` (sign-in plus the learned length)
or `renewalNotification` (Appgate's own 5-minute countdown has started).
`sessionStartKind` is `signIn` or `renewal`. Fields that don't apply are left
out. On errors you get `{"state": "error", "exitCode": 3, "error": "..."}`.

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

## Menu bar app

`Gatekeepr.app` puts the time left in the menu bar, using the same text as
`gatekeepr --short`:

| Menu bar | Meaning |
|---|---|
| clock `6h08m` | Signed in, more than the warn threshold left |
| orange hourglass `25m` | Signed in, inside the warn window |
| red `expired` | The session ran out |
| `signed out` / `no session` | Not signed in |
| red triangle `error` | The logs can't be read, or don't look the way gatekeepr expects (the CLI's exit code 3). The menu shows why. It never falls back to a guess |

The menu shows the sign-in time, the expiry, the time left and how many past
sessions the length was learned from (the same lines `gatekeepr` prints), your
recent sessions, **Open Appgate**, **Warn Before Expiry** (5 minutes to 2 hours,
default 30 minutes, remembered), **Launch at Login** and **Quit**.

- **Notifications.** You get one when the session enters the warn window, and
  one when it expires, once per session each. Gatekeepr remembers which session
  it already told you about, so restarting the app doesn't repeat them. An
  expiry more than 15 minutes old isn't announced, so starting the app (or
  opening the laptop) the morning after doesn't ping you about last night's
  session; the menu bar already says `expired`. Click a notification to open
  Appgate SDP.
- **Live updates.** The app watches `/var/log/appgate` for changes (kqueue, no
  polling), so signing in, signing out or renewing shows up within a second. It
  follows `driver.log` through Appgate's nightly log rotation. The only timer
  ticks the countdown once a minute.
- **Launch at Login** uses `SMAppService`, so the app shows up under System
  Settings › General › Login Items. Move `Gatekeepr.app` to Applications first.
- **No Dock icon** (`LSUIElement`).
- **Not sandboxed, and can't be.** It reads `/var/log/appgate`, which a
  sandboxed app has no access to. That's also why it won't be on the App Store.
  Like the CLI, it needs no root and makes no network calls.

### Build the app

```sh
scripts/build-app
open build/Gatekeepr.app        # or move it to /Applications first
```

The script builds a release binary, wraps it in `build/Gatekeepr.app` and signs
it ad hoc.

> **Unsigned for now.** There's no Developer ID certificate yet, so the app is
> ad-hoc signed and not notarized. A copy you built yourself runs as is. A copy
> from somewhere else is blocked by Gatekeeper the first time: right-click it in
> Finder, pick **Open**, then confirm. Signed, notarized releases come later.

To point the app at a different log directory (like the CLI's `--log-dir`):

```sh
defaults write io.github.akramsaouri.gatekeepr logDirectory /path/to/logs
open build/Gatekeepr.app --args -logDirectory /path/to/logs   # one run only
```

## How it works

There is no API for any of this. Everything comes from `driver.log` and the
rotated `driver-YYYY-MM-DD.log.gz` files, read oldest first. Each line looks
like `[2026-10-10T23:24:41.741Z] Info : <message>`, in UTC.

- **Sign-in.** The client sends a `login` to each site (AWS and GCP, say) within
  a second or two; that's one sign-in. A login counts as a sign-in when the
  previous session is over: the client closed its control connection
  (`Closing *:0 (Client closed control connection)`), the client opened a new
  control connection, or the driver restarted (after a reboot, for example).
  The first login in the log history counts too.
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

These rules come from Appgate client 6.5.3 talking to gateway 6.5.6. If your
version behaves differently, please open an issue with a sanitized log.

## Sharing logs

Raw Appgate logs contain gateway hostnames, IP addresses, MAC addresses, device
IDs and your e-mail address. Before attaching a log to an issue, run it through
the sanitizer, which swaps all of those (and anything token-like) for stable
fake values:

```sh
scripts/sanitize-log /var/log/appgate/driver.log > driver.sanitized.log
scripts/sanitize-log --check driver.sanitized.log   # reports anything that still looks real
```

It needs only Python 3. Read the output before you share it anyway.

## Development

```sh
swift build
swift test
scripts/build-app
```

| Target | What it is |
|---|---|
| `GatekeeprCore` | Reads the logs, splits them into sessions, learns the length, computes expiry. Also the wording both front ends share (`StatusText`) |
| `gatekeepr` | The CLI |
| `GatekeeprMenuBar` | The menu bar app's logic: what the menu shows in each state, notification bookkeeping, settings and the log watcher. No UI, unit-tested |
| `GatekeeprApp` | The SwiftUI `MenuBarExtra` and the system glue (notifications, launch at login, opening Appgate). `scripts/build-app` turns it into `Gatekeepr.app`. It isn't called `Gatekeepr` because on a case-insensitive disk that would collide with the `gatekeepr` CLI in `.build/` |

All the session logic is in `GatekeeprCore`; the app doesn't make any decisions
of its own about sessions. `swift run GatekeeprApp` starts the app without a
bundle, which is handy for working on the menu, but notifications and launch at
login only work from `Gatekeepr.app`.

Core tests run against sanitized excerpts of real logs in
`Tests/GatekeeprCoreTests/Fixtures`; see the README there. The menu bar tests
write small synthetic logs and go through the same parser. Never commit raw
logs: `.gitignore` blocks `*.log` and `*.log.gz` outside the fixtures directory,
and CI runs `scripts/sanitize-log --check` over the fixtures.
