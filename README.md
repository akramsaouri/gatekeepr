# gatekeepr

A macOS CLI that tells you when your Appgate session expires. Unofficial, not
affiliated with Appgate.

## Install

Needs macOS 13 or later. From the [latest release](https://github.com/akramsaouri/gatekeepr/releases/latest):

```sh
version=0.3.0
base=https://github.com/akramsaouri/gatekeepr/releases/download/v$version
curl -fLO "$base/gatekeepr-$version-macos-universal.tar.gz"
curl -fLO "$base/SHA256SUMS"
shasum -a 256 -c --ignore-missing SHA256SUMS   # must print OK
tar -xzf "gatekeepr-$version-macos-universal.tar.gz"
sudo install "gatekeepr-$version-macos-universal/gatekeepr" /usr/local/bin/
```

Downloaded in a browser instead? Run `xattr -d com.apple.quarantine "gatekeepr-$version-macos-universal/gatekeepr"` before installing, or macOS won't run it.

Or with Go 1.26 or later:

```sh
go install github.com/akramsaouri/gatekeepr@latest
```

The binary goes to `$(go env GOPATH)/bin` (usually `~/go/bin`), which must be on your `PATH`.

## Usage

`gatekeepr` shows the sign-in time, expiry and time left:

```console
$ gatekeepr
Appgate session active
  Signed in  Sun 11 Oct 01:24
  Expires    Mon 12 Oct 01:24
  Time left  6h08m
  Length     24h00m, the median of 17 measured sessions
```

`--short` prints just the time left, for statuslines:

```console
$ gatekeepr --short
6h08m
```

`--json` prints the status as JSON. Fields and states are in [docs/JSON.md](docs/JSON.md).

```console
$ gatekeepr --json
{
  "exitCode" : 0,
  "expiresAt" : "2026-10-12T01:24:40+02:00",
  ...
  "state" : "active",
  "timeLeft" : "6h08m",
  ...
}
```

`history` lists past sessions:

```console
$ gatekeepr history
Start             How      End               Outcome      Length  Reconnects
Fri 11 Sep 09:31  renewal  Sat 12 Sep 09:31  expired      24h00m  0
Sun 11 Oct 01:24  sign-in  -                 active       -       1
```

`--warn <duration>` exits with 1 when that much time or less is left (default `30m`). All exit codes are in [docs/JSON.md](docs/JSON.md#exit-codes).

```console
$ gatekeepr --short --warn 1h || echo "Appgate session ending soon"
45m
Appgate session ending soon
```

## How it works

gatekeepr reads Appgate's driver logs in `/var/log/appgate`, which any user can
read, so it needs no root and makes no network calls. It learns your session
length from past sessions and adds it to your sign-in time. The rules come from
observed logs, not a documented API, so when the logs don't look as expected it
exits with 3 instead of guessing.

## Reporting a parse failure

If gatekeepr exits with 3 and says it "won't guess", send a sanitized excerpt:

1. Copy a few dozen lines around the file and line from the error, and sanitize
   them with [`scripts/sanitize-log`](https://raw.githubusercontent.com/akramsaouri/gatekeepr/main/scripts/sanitize-log)
   (needs Python 3, not in the release tarball):

   ```sh
   gzcat /var/log/appgate/driver-2026-10-10.log.gz | sed -n '1200,1270p' > excerpt.log
   # live log: sed -n '1200,1270p' /var/log/appgate/driver.log > excerpt.log
   scripts/sanitize-log excerpt.log > excerpt.sanitized.log
   scripts/sanitize-log --check excerpt.sanitized.log   # flags anything that still looks real
   ```

2. Read `excerpt.sanitized.log` yourself.
3. [Open an issue](https://github.com/akramsaouri/gatekeepr/issues/new) with the
   excerpt, the error minus its `Line: ...` part (that's the raw log line),
   `gatekeepr --version`, and your Appgate client version:
   `gzcat -f /var/log/appgate/driver*.log* | grep loop_init | tail -1`.
