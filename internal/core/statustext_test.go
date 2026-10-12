package core

import (
	"reflect"
	"strings"
	"testing"
	"time"
)

func stockholm(t *testing.T) *time.Location {
	t.Helper()
	loc, err := time.LoadLocation("Europe/Stockholm")
	if err != nil {
		t.Fatal(err)
	}
	return loc
}

func rows(summary Summary) []string {
	var result []string
	for _, row := range summary.Rows {
		result = append(result, row.Label+": "+row.Value)
	}
	return result
}

func TestShortStatus(t *testing.T) {
	for _, c := range []struct{ fixture, now, want string }{
		{"normal-day", "2026-10-09T12:00:00Z", "19h55m"},
		{"normal-day", "2026-10-10T09:00:00Z", "expired"},
		{"empty", "2026-10-10T12:00:00Z", "no session"},
		// The rotation fixture's 6 Oct session ends with a driver restart.
		{"rotation", "2026-10-07T06:15:00Z", "signed out"},
	} {
		if got := ShortStatus(statusOf(t, c.fixture, c.now, defaultWarn)); got != c.want {
			t.Errorf("%s at %s: got %s", c.fixture, c.now, got)
		}
	}
}

func TestSummaryWhileActive(t *testing.T) {
	summary := Summarize(statusOf(t, "normal-day", "2026-10-09T12:00:00Z", defaultWarn), AppgateLogDirectory, stockholm(t))
	if summary.Heading != "Appgate session active" {
		t.Errorf("heading %q", summary.Heading)
	}
	want := []string{"Signed in: Fri 9 Oct 09:55", "Expires: Sat 10 Oct 09:55", "Time left: 19h55m", "Length: 24h00m, measured from 1 session"}
	if got := rows(summary); !reflect.DeepEqual(got, want) {
		t.Errorf("rows %q", got)
	}
}

func TestSummaryInWarnWindowWithRenewalNotice(t *testing.T) {
	summary := Summarize(statusOf(t, "reconnect", "2026-09-29T07:18:00Z", defaultWarn), AppgateLogDirectory, stockholm(t))
	if summary.Heading != "Appgate session expires soon (warning at 30m)" || summary.Rows[1].Value != "Tue 29 Sep 09:21, per Appgate's expiry warning" {
		t.Errorf("summary %+v", summary)
	}
}

func TestSummaryWhenExpiredAndSignedOut(t *testing.T) {
	expired := Summarize(statusOf(t, "normal-day", "2026-10-10T09:00:00Z", defaultWarn), "/x", stockholm(t))
	want := []string{"Signed in: Fri 9 Oct 09:55", "Expired: Sat 10 Oct 09:55 (1h04m ago)", "Length: 24h00m, measured from 1 session"}
	if got := rows(expired); !reflect.DeepEqual(got, want) {
		t.Errorf("rows %q", got)
	}
	signedOut := Summarize(statusOf(t, "rotation", "2026-10-07T06:15:00Z", defaultWarn), "/x", stockholm(t))
	if signedOut.Heading != "Not signed in to Appgate" || signedOut.Rows[0].Label != "Last session" ||
		!strings.HasSuffix(signedOut.Rows[1].Value, "(the Appgate driver restarted)") {
		t.Errorf("summary %+v", signedOut)
	}
}

func TestSummaryEndReasons(t *testing.T) {
	for _, c := range []struct {
		end     EventKind
		outcome Outcome
		want    string
	}{
		{ClientClosed, OutcomeSignedOut, "Sat 10 Oct 10:00 (signed out)"},
		{ClientConnected, OutcomeInterrupted, "Sat 10 Oct 10:00 (the Appgate client restarted)"},
		{DriverRestarted, OutcomeInterrupted, "Sat 10 Oct 10:00 (the Appgate driver restarted)"},
	} {
		status := analysisOf([]Event{login(0), event(2, c.end)}, 3).Status(defaultWarn)
		if status.State != SignedOut || status.Outcome != c.outcome {
			t.Errorf("%v: state %s, outcome %s", c.end, status.State, status.Outcome)
		}
		if got := Summarize(status, "/x", time.UTC).Rows[1].Value; got != c.want {
			t.Errorf("%v: ended %q", c.end, got)
		}
	}
}

func TestSummaryWithNoSession(t *testing.T) {
	summary := Summarize(statusOf(t, "empty", "2026-10-10T12:00:00Z", defaultWarn), AppgateLogDirectory, time.UTC)
	if summary.Heading != "No Appgate session found in /var/log/appgate." || len(summary.Rows) != 0 {
		t.Errorf("summary %+v", summary)
	}
}

func TestFormatSessionLength(t *testing.T) {
	if got := FormatSessionLength(SessionLength{Duration: 24 * time.Hour}); got != "24h00m (default, no measured sessions yet)" {
		t.Errorf("got %s", got)
	}
	if got := FormatSessionLength(SessionLength{Duration: 86_399_200 * time.Millisecond, LearnedFrom: 17}); got != "24h00m, the median of 17 measured sessions" {
		t.Errorf("got %s", got)
	}
}
