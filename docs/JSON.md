# `--json` output and exit codes

`gatekeepr --json` and `gatekeepr history --json` print one JSON object on
stdout. This page is the contract for scripts and other programs that read it.

## Versioning

Every object has `schemaVersion`. It is **1** for the schema on this page. Any
change to the schema bumps it: a field added, removed or renamed, a new value
for an enum field, or a change to what a field means or when it's present.
Within one `schemaVersion` the shape stays exactly as described here.

Check `schemaVersion` before reading anything else, and treat a version you
don't know as an error rather than guessing.

gatekeepr v0.2.x printed the same fields minus `schemaVersion` and
`sessionLengthSource`.

General rules:

- Times are ISO 8601 strings with the UTC offset of the local time zone, to
  the second (fractions are dropped, not rounded): `2026-10-12T01:24:40+02:00`,
  or `...Z` when the offset is zero. Use `TZ=UTC gatekeepr --json` for UTC.
- Durations are whole seconds.
- Fields that don't apply are left out, never `null`. Which fields are present
  in which state is listed below.
- Key order and whitespace are not part of the contract. (The keys happen to
  be sorted.)
- On stderr, gatekeepr prints nothing unless something went wrong.

## `gatekeepr --json`

```console
$ gatekeepr --json
{
  "exitCode" : 1,
  "expiresAt" : "2026-10-10T09:55:34+02:00",
  "expirySource" : "sessionLength",
  "now" : "2026-10-10T09:30:00+02:00",
  "schemaVersion" : 1,
  "secondsLeft" : 1534,
  "sessionLengthLearnedFrom" : 1,
  "sessionLengthSeconds" : 86399,
  "sessionLengthSource" : "median",
  "sessionStart" : "2026-10-09T09:55:35+02:00",
  "sessionStartKind" : "signIn",
  "state" : "expiringSoon",
  "timeLeft" : "25m",
  "warnThresholdSeconds" : 1800
}
```

| Field | Type | Meaning |
|---|---|---|
| `schemaVersion` | integer | `1` |
| `state` | string | `active`, `expiringSoon`, `expired`, `signedOut` or `noSession` (see below) |
| `exitCode` | integer | The exit code gatekeepr exits with, the same as the process's |
| `now` | time | When gatekeepr read the logs |
| `warnThresholdSeconds` | integer | The `--warn` threshold (default 1800) |
| `sessionLengthSeconds` | integer | How long a session lasts, as gatekeepr worked it out |
| `sessionLengthSource` | string | How: `median` (the median of `sessionLengthLearnedFrom` measured sessions) or `default` (no session could be measured yet, so 24 hours) |
| `sessionLengthLearnedFrom` | integer | How many past sessions the median was taken over; `0` with `default` |
| `sessionStart` | time | When the current (or, when signed out, the last) session started: a sign-in, or a renewal from Appgate's expiry warning |
| `sessionStartKind` | string | `signIn` or `renewal` |
| `sessionEnd` | time | When that session ended: the client closed it (sign-out or expiry), or Appgate restarted. Absent while it's open |
| `expiresAt` | time | When the session expires (or expired) |
| `expirySource` | string | `sessionLength` (`sessionStart` plus `sessionLengthSeconds`) or `renewalNotification` (Appgate's own 5-minute countdown has started, and wins) |
| `secondsLeft` | integer | `expiresAt` minus `now`, rounded down. Negative once expired |
| `timeLeft` | string | The same, as `6h08m`, `25m` or `<1m`, rounded down; `0m` once expired. What `--short` prints when signed in |

### States

| `state` | `exitCode` | Meaning | Fields present |
|---|---|---|---|
| `active` | 0 | Signed in, more than the warn threshold left | all but `sessionEnd` |
| `expiringSoon` | 1 | Signed in, no more than the warn threshold left | all but `sessionEnd` |
| `expired` | 2 | The session ran out. `sessionEnd` is there once the client has closed it | all; `sessionEnd` only after the close |
| `signedOut` | 2 | Not signed in: signed out early, or Appgate restarted mid-session | all. `expiresAt`, `secondsLeft` and `timeLeft` describe when the last session would have expired, so check `state` first |
| `noSession` | 2 | No session anywhere in the logs | `schemaVersion`, `state`, `exitCode`, `now`, `warnThresholdSeconds`, `sessionLength*` |

### Errors

When the logs can't be read, or don't look the way gatekeepr expects, it
exits with 3, prints the reason on stderr (`gatekeepr: ...`), and prints:

```json
{
  "error" : "driver.log:1: this line doesn't match any known Appgate log format, so gatekeepr won't guess. Line: ...",
  "exitCode" : 3,
  "schemaVersion" : 1,
  "state" : "error"
}
```

| Field | Type | Meaning |
|---|---|---|
| `schemaVersion` | integer | `1` |
| `state` | string | `error` |
| `exitCode` | integer | `3` |
| `error` | string | What went wrong, for people: the wording isn't part of the contract. Parse errors start with the file and line, like `driver.log:120:` |

## `gatekeepr history --json`

```console
$ gatekeepr history --json
{
  "now" : "2026-09-28T10:00:00+02:00",
  "schemaVersion" : 1,
  "sessionLengthLearnedFrom" : 0,
  "sessionLengthSeconds" : 86400,
  "sessionLengthSource" : "default",
  "sessions" : [
    {
      "end" : "2026-09-28T09:07:34+02:00",
      "endKind" : "clientClosed",
      "expiresAt" : "2026-09-29T08:35:30+02:00",
      "expirySource" : "sessionLength",
      "outcome" : "signedOut",
      "reconnects" : 1,
      "start" : "2026-09-28T08:35:30+02:00",
      "startKind" : "signIn"
    }
  ]
}
```

`schemaVersion`, `now` and the three `sessionLength*` fields mean the same as
above. `sessions` lists every session in the logs, oldest first; it's empty
(`[]`) when there are none. Each session has:

| Field | Type | Meaning |
|---|---|---|
| `start` | time | When it started |
| `startKind` | string | `signIn` or `renewal` |
| `end` | time | When it ended. Absent while it's open (only the last session can be) |
| `endKind` | string | `clientClosed` (signed out, or closed on expiry), `clientRestarted`, `driverRestarted` or `renewed`. Absent while it's open |
| `outcome` | string | `active`, `expired`, `signedOut`, `renewed` or `interrupted` (cut short by a client or driver restart) |
| `expiresAt` | time | When it expires or expired |
| `expirySource` | string | `sessionLength` or `renewalNotification`, as above |
| `measuredLengthSeconds` | integer | Sign-in to Appgate's first expiry warning plus that warning's countdown: what the session length is learned from. Absent if no warning was seen |
| `reconnects` | integer | Gateway reconnects during the session. They don't restart it |

`history` exits with 0, or with 3 and the error object above.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Signed in, more than the warn threshold left (`active`) |
| 1 | Signed in, within the warn threshold (`expiringSoon`) |
| 2 | Expired, signed out, or no session (`expired`, `signedOut`, `noSession`) |
| 3 | The logs can't be read, or are in a format gatekeepr doesn't recognise (`error`) |
| 64 | The command line is wrong: an unknown option, a bad `--warn` value, `--json` with `--short`. The message is on stderr and nothing is printed on stdout |

`--help` and `--version` exit with 0.
