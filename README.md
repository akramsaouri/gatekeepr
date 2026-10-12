# gatekeepr

A macOS CLI that tells you when your Appgate session expires. Unofficial, not
affiliated with Appgate.

## Install

Needs macOS 13 or later and Go 1.26 or later:

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

