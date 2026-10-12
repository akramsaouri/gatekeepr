# Golden files

Each `<case>.txt` pins what one gatekeepr run prints and exits with. The test
is `TestGolden` in `golden_test.go`, which runs the command line in-process
with the case's clock, time zone and terminal width.

```
args: --log-dir testdata/fixtures/normal-day --short
now: 2026-10-09T12:00:00Z
tz: Europe/Stockholm
exit: 0
-- stdout --
19h55m
-- stderr --
```

- `args` are quoted the way bash's `printf %q` quotes them, and run from the
  repository root, so `--log-dir testdata/fixtures/...` points at the
  [fixtures](../fixtures).
- `now` is the clock: log lines after it are ignored.
- `tz` is the time zone times are shown in.
- `columns`, when present, is the terminal width help is wrapped to (80
  otherwise).
- `{{CWD}}` in the output stands for the working directory: some errors print
  the log directory as an absolute path.

## Where they came from

The Go version replaced a Swift one (v0.1 to v0.2.1). Before the Swift code
was deleted, its CLI recorded every case here, with a capture-only clock
override. The Go version reproduces that output byte for byte, except for:

- `--version`, which says `0.3.0` instead of `0.2.1`, and
- `--json`, which gained `schemaVersion` and `sessionLengthSource` in schema v1
  ([docs/JSON.md](../../docs/JSON.md)). Those cases keep the Swift output
  under `-- swift-stdout --`, and the test checks that the Go JSON is exactly
  that plus the two new fields.

The cases cover every state in default, `--short` and `--json` output (active,
in the warn window, expired before and after the client closes, signed out by
the user or by a driver restart, no session), history, unreadable and
unparseable logs, other time zones, every option form, help at several widths,
and swift-argument-parser's usage errors and the order it reports them in.

## Updating

After an intended change to the output:

```sh
go test -run TestGolden -update
git diff testdata/golden
```

`-update` rewrites `stdout`, `stderr` and `exit` of every case from the
current output, and leaves `swift-stdout` alone. Review the diff before
committing it. To add a case, write the header lines and empty `stdout` and
`stderr` sections, then run with `-update`.
