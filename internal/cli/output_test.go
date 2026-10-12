package cli

import (
	"strings"
	"testing"
	"time"

	"github.com/akramsaouri/gatekeepr/internal/core"
)

// Rendering on hand-built statuses and histories. The golden files cover the
// same output end to end, from the fixtures.

// base is Sat 10 Oct 08:00 UTC.
var base = time.Date(2026, 10, 10, 8, 0, 0, 0, time.UTC)

// statusAt is the status of a session that started at base and expires 24h
// later, as seen at base plus now.
func statusAt(state core.State, outcome core.Outcome, now time.Duration, session core.Session, source core.ExpirySource) core.Status {
	session.Start = base
	return core.Status{
		State:         state,
		Now:           base.Add(now),
		Session:       &session,
		Expiry:        &core.Expiry{Date: base.Add(24 * time.Hour), Source: source},
		Outcome:       outcome,
		WarnThreshold: 30 * time.Minute,
		SessionLength: core.SessionLength{Duration: 24 * time.Hour},
	}
}

func TestStatusText(t *testing.T) {
	renewed := statusAt(core.Active, core.OutcomeActive, 4*time.Hour, core.Session{StartKind: core.Renewal}, core.FromRenewalNotification)
	renewed.SessionLength.LearnedFrom = 3
	ended := func(kind core.SessionEnd, outcome core.Outcome) core.Status {
		return statusAt(core.SignedOut, outcome, 3*time.Hour, core.Session{End: base.Add(2 * time.Hour), EndKind: kind}, core.FromSessionLength)
	}
	for _, c := range []struct {
		name   string
		status core.Status
		want   string
	}{
		{"renewed, per the gateway", renewed, `Appgate session active
  Renewed    Sat 10 Oct 08:00
  Expires    Sun 11 Oct 08:00, per Appgate's expiry warning
  Time left  20h00m
  Length     24h00m, the median of 3 measured sessions`},
		{"expiring soon", statusAt(core.ExpiringSoon, core.OutcomeActive, 23*time.Hour+50*time.Minute, core.Session{StartKind: core.SignIn}, core.FromSessionLength), `Appgate session expires soon (warning at 30m)
  Signed in  Sat 10 Oct 08:00
  Expires    Sun 11 Oct 08:00
  Time left  10m
  Length     24h00m (default, no measured sessions yet)`},
		{"expired", statusAt(core.Expired, core.OutcomeExpired, 25*time.Hour+30*time.Minute, core.Session{StartKind: core.SignIn}, core.FromSessionLength), `Appgate session expired
  Signed in  Sat 10 Oct 08:00
  Expired    Sun 11 Oct 08:00 (1h30m ago)
  Length     24h00m (default, no measured sessions yet)`},
		{"signed out", ended(core.ClientClosedEnd, core.OutcomeSignedOut), `Not signed in to Appgate
  Last session  Sat 10 Oct 08:00
  Ended         Sat 10 Oct 10:00 (signed out)`},
		{"client restarted", ended(core.ClientRestarted, core.OutcomeInterrupted), `Not signed in to Appgate
  Last session  Sat 10 Oct 08:00
  Ended         Sat 10 Oct 10:00 (the Appgate client restarted)`},
		{"driver restarted", ended(core.DriverRestartedEnd, core.OutcomeInterrupted), `Not signed in to Appgate
  Last session  Sat 10 Oct 08:00
  Ended         Sat 10 Oct 10:00 (the Appgate driver restarted)`},
		{"no session", core.Status{State: core.NoSession, Now: base}, "No Appgate session found in /var/log/appgate."},
	} {
		if got := statusText(c.status, core.AppgateLogDirectory, time.UTC); got != c.want {
			t.Errorf("%s:\n%s\nwant\n%s", c.name, got, c.want)
		}
	}
}

func TestShortStatus(t *testing.T) {
	for _, c := range []struct {
		status core.Status
		want   string
	}{
		{statusAt(core.Active, core.OutcomeActive, 4*time.Hour+30*time.Second, core.Session{}, core.FromSessionLength), "19h59m"},
		{statusAt(core.ExpiringSoon, core.OutcomeActive, 24*time.Hour-30*time.Second, core.Session{}, core.FromSessionLength), "<1m"},
		{statusAt(core.Expired, core.OutcomeExpired, 25*time.Hour, core.Session{}, core.FromSessionLength), "expired"},
		{statusAt(core.SignedOut, core.OutcomeInterrupted, 3*time.Hour, core.Session{End: base.Add(time.Hour), EndKind: core.DriverRestartedEnd}, core.FromSessionLength), "signed out"},
		{core.Status{State: core.NoSession}, "no session"},
	} {
		if got := shortStatus(c.status); got != c.want {
			t.Errorf("%s: got %s, want %s", c.status.State, got, c.want)
		}
	}
}

func TestHistoryText(t *testing.T) {
	notice := &core.RenewalNotice{Date: base.Add(26*time.Hour + 50*time.Minute), TimeLeft: 5 * time.Minute}
	analysis := core.Analysis{
		Now:           base.Add(30 * time.Hour),
		SessionLength: core.SessionLength{Duration: 24 * time.Hour, LearnedFrom: 1},
		Sessions: []core.Session{
			{Start: base, StartKind: core.SignIn, End: base.Add(2 * time.Hour), EndKind: core.ClientClosedEnd},
			{Start: base.Add(3 * time.Hour), StartKind: core.SignIn, End: notice.Expiry(), EndKind: core.Renewed,
				FirstRenewalNotice: notice, LastRenewalNotice: notice, Reconnects: 2},
			{Start: notice.Expiry(), StartKind: core.Renewal},
		},
	}
	want := strings.Join([]string{
		"Start             How      End               Outcome     Length  Reconnects",
		"Sat 10 Oct 08:00  sign-in  Sat 10 Oct 10:00  signed out  -       0",
		"Sat 10 Oct 11:00  sign-in  Sun 11 Oct 10:55  renewed     23h55m  2",
		"Sun 11 Oct 10:55  renewal  -                 active      -       0",
		"",
		"Session length: 24h00m, measured from 1 session.",
		`Length is sign-in to Appgate's first expiry warning plus the warning's countdown; "-" means no warning was seen.`,
	}, "\n")
	if got := historyText(analysis, "/x", time.UTC); got != want {
		t.Errorf("got\n%s\nwant\n%s", got, want)
	}
	if got := historyText(core.Analysis{Now: base}, "/x", time.UTC); got != "No Appgate sessions found in /x." {
		t.Errorf("got %s", got)
	}
}

func TestFormatSessionLength(t *testing.T) {
	if got := formatSessionLength(core.SessionLength{Duration: 24 * time.Hour}); got != "24h00m (default, no measured sessions yet)" {
		t.Errorf("got %s", got)
	}
	if got := formatSessionLength(core.SessionLength{Duration: 86_399_200 * time.Millisecond, LearnedFrom: 17}); got != "24h00m, the median of 17 measured sessions" {
		t.Errorf("got %s", got)
	}
}

func TestExitCodes(t *testing.T) {
	for state, want := range map[core.State]int{
		core.Active: 0, core.ExpiringSoon: 1, core.Expired: 2, core.SignedOut: 2, core.NoSession: 2,
	} {
		if got := exitCode(state); got != want {
			t.Errorf("%s: got %d, want %d", state, got, want)
		}
	}
}
