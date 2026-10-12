# Test fixtures

Each directory is a stand-in for `/var/log/appgate`, used with `--log-dir` or
`core.New(dir, clock)`. The logs are trimmed excerpts of real Appgate client
6.5.3 logs (talking to gateway 6.5.6), run through `scripts/sanitize-log` and
reviewed by hand. Route tables, DNS lookups and most repeated network noise were
dropped to keep them small; every line that matters for sessions was kept as is.
Hostnames, IPs, UUIDs and tokens are fake: `hostN.example`, `198.18.x.x`,
`2001:db8::N`, `00000000-0000-4000-8000-…`.

CI runs `scripts/sanitize-log --check` over this directory, so anything that
looks like a real address or token fails the build.

| Directory | What it shows |
|---|---|
| `normal-day` | A session that runs into its expiry warning and closes, the next morning's sign-in (one login per site), then a day of `update-tokens` refreshes and noise. |
| `reconnect` | A session with a token revocation (`deploy` + `update-tokens`) and a `Disconnected by gateway` reconnect with a fresh `login`. Neither resets the session. |
| `expired` | Renewal notifications counting down from 300 s to 0, then the client closing. |
| `renewal` | Renewing in place from the expiry warning: a `deploy` + `update-tokens` while the countdown runs, with no close and no login. The next warning comes 23h55m later. |
| `rotation` | Three rotated `driver-YYYY-MM-DD.log.gz` days plus `driver.log`. Sessions span files, and one sign-in follows a driver restart with no client close before it. |
| `signed-out` | A sign-in, a dead-connection reconnect, then the user signing out: the client closes its connections on real ports (`*:62973`, not `*:0`) and the driver stops. |
| `empty` | An empty `driver.log`. |
| `no-log-files` | A `driver.status` and no driver logs. |
| `unknown-format` | The `normal-day` lines rewritten in a made-up layout, to check gatekeepr refuses to guess. |
