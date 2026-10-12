package core

import (
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"
)

// End-to-end runs over the fixture log directories.

func TestNormalDayIsActiveWithExpiryFromLearnedLength(t *testing.T) {
	status := statusOf(t, "normal-day", "2026-10-09T12:00:00Z", defaultWarn)
	if status.State != Active {
		t.Fatalf("state %s", status.State)
	}
	// AWS and GCP both log in at 07:55:35.444: one sign-in.
	assertDate(t, status.Session.Start, utc(t, "2026-10-09T07:55:35.444Z"))
	if status.Session.StartKind != SignIn {
		t.Errorf("start kind %s", status.Session.StartKind)
	}
	// Learned from the previous session: first notice at 07:37:22.620 with
	// 300 s left, signed in at 07:42:23.386 the day before.
	if status.SessionLength.LearnedFrom != 1 {
		t.Errorf("learned from %d", status.SessionLength.LearnedFrom)
	}
	assertSeconds(t, status.SessionLength.Duration, 86_399.234)
	if status.Expiry.Source != FromSessionLength {
		t.Errorf("source %s", status.Expiry.Source)
	}
	assertDate(t, status.Expiry.Date, utc(t, "2026-10-10T07:55:34.678Z"))
	left, _ := status.TimeLeft()
	assertSeconds(t, left, 19*3600+55*60+34.678)
}

func TestNormalDayHistory(t *testing.T) {
	analysis := analyzeFixture(t, "normal-day", "2026-10-09T12:00:00Z")
	if len(analysis.Sessions) != 2 {
		t.Fatalf("%d sessions", len(analysis.Sessions))
	}
	previous := analysis.Sessions[0]
	assertDate(t, previous.Start, utc(t, "2026-10-08T07:42:23.386Z"))
	assertDate(t, previous.End, utc(t, "2026-10-09T07:42:22.616Z"))
	if previous.EndKind != ClientClosedEnd || analysis.Outcome(previous) != OutcomeExpired {
		t.Errorf("end %s, outcome %s", previous.EndKind, analysis.Outcome(previous))
	}
	// The dead-connection reconnect at 21:19 the same evening.
	if previous.Reconnects != 1 {
		t.Errorf("reconnects %d", previous.Reconnects)
	}
	if analysis.Outcome(analysis.Sessions[1]) != OutcomeActive {
		t.Error("the second session should be active")
	}
}

func TestNormalDayWarnWindow(t *testing.T) {
	status := statusOf(t, "normal-day", "2026-10-10T07:30:00Z", defaultWarn)
	if status.State != ExpiringSoon {
		t.Errorf("state %s", status.State)
	}
	if relaxed := statusOf(t, "normal-day", "2026-10-10T07:30:00Z", 10*time.Minute); relaxed.State != Active {
		t.Errorf("relaxed state %s", relaxed.State)
	}
}

func TestNormalDayPastExpiryWithoutCloseIsExpired(t *testing.T) {
	// The log just stops (laptop asleep); the learned expiry has passed.
	status := statusOf(t, "normal-day", "2026-10-10T09:00:00Z", defaultWarn)
	if status.State != Expired {
		t.Errorf("state %s", status.State)
	}
}

func TestFirstSessionInHistoryFallsBackTo24Hours(t *testing.T) {
	status := statusOf(t, "normal-day", "2026-10-08T12:00:00Z", defaultWarn)
	if status.State != Active || !status.SessionLength.IsFallback() || status.SessionLength.Duration != 24*time.Hour {
		t.Errorf("state %s, length %+v", status.State, status.SessionLength)
	}
	assertDate(t, status.Expiry.Date, utc(t, "2026-10-09T07:42:23.386Z"))
}

func TestGatewayReconnectDoesNotResetSession(t *testing.T) {
	// 07:02 a token revocation brings a deploy + update-tokens; 07:11 the
	// gateway disconnects and the client logs in again. Neither is a sign-in.
	status := statusOf(t, "reconnect", "2026-09-29T07:12:30Z", 5*time.Minute)
	if status.State != Active || status.Session.Reconnects != 1 {
		t.Errorf("state %s, reconnects %d", status.State, status.Session.Reconnects)
	}
	assertDate(t, status.Session.Start, utc(t, "2026-09-28T07:21:20.113Z"))
	assertDate(t, status.Expiry.Date, utc(t, "2026-09-29T07:21:20.113Z"))
}

func TestRenewalNotificationOverridesTheTimingModel(t *testing.T) {
	status := statusOf(t, "reconnect", "2026-09-29T07:18:00Z", defaultWarn)
	if status.State != ExpiringSoon || status.Expiry.Source != FromRenewalNotification {
		t.Errorf("state %s, source %s", status.State, status.Expiry.Source)
	}
	// Last notice before 07:18: 07:17:18.631 with 240 s left.
	assertDate(t, status.Expiry.Date, utc(t, "2026-09-29T07:21:18.631Z"))
}

func TestCountdownToExpiry(t *testing.T) {
	status := statusOf(t, "expired", "2026-10-10T07:53:00Z", defaultWarn)
	if status.State != ExpiringSoon || status.Expiry.Source != FromRenewalNotification {
		t.Errorf("state %s, source %s", status.State, status.Expiry.Source)
	}
	// 07:52:34 notice, 180 s left.
	if diff := status.Expiry.Date.Sub(utc(t, "2026-10-10T07:55:34Z")); diff > time.Second || diff < -time.Second {
		t.Errorf("expiry %s", status.Expiry.Date)
	}
}

func TestExpiredBeforeTheClientCloses(t *testing.T) {
	// The last notice said 0 s left at 07:55:34.384; the client closes at 07:55:36.888.
	status := statusOf(t, "expired", "2026-10-10T07:55:35.500Z", defaultWarn)
	if status.State != Expired || !status.Session.IsOpen() {
		t.Errorf("state %s, open %v", status.State, status.Session.IsOpen())
	}
}

func TestExpiredAfterTheClientCloses(t *testing.T) {
	status := statusOf(t, "expired", "2026-10-10T08:00:00Z", defaultWarn)
	if status.State != Expired {
		t.Errorf("state %s", status.State)
	}
	assertDate(t, status.Session.End, utc(t, "2026-10-10T07:55:36.888Z"))
	length, _ := status.Session.MeasuredLength()
	assertSeconds(t, length, 86_398.929)
}

func TestRenewingFromTheWarningStartsANewSession(t *testing.T) {
	analysis := analyzeFixture(t, "renewal", "2026-09-12T08:00:00Z")
	if len(analysis.Sessions) != 2 {
		t.Fatalf("%d sessions", len(analysis.Sessions))
	}
	first := analysis.Sessions[0]
	assertDate(t, first.Start, utc(t, "2026-09-10T07:36:27.387Z"))
	if first.EndKind != Renewed || analysis.Outcome(first) != OutcomeRenewed {
		t.Errorf("end %s, outcome %s", first.EndKind, analysis.Outcome(first))
	}
	// Four network reconnects that day, each with its own deploy and logins.
	if first.Reconnects != 4 {
		t.Errorf("reconnects %d", first.Reconnects)
	}
	length, _ := first.MeasuredLength()
	assertSeconds(t, length, 86_398.739)

	renewed := analysis.Sessions[1]
	if renewed.StartKind != Renewal || analysis.Outcome(renewed) != OutcomeExpired {
		t.Errorf("start %s, outcome %s", renewed.StartKind, analysis.Outcome(renewed))
	}
	assertDate(t, renewed.Start, utc(t, "2026-09-11T07:31:43.100Z"))
	length, _ = renewed.MeasuredLength()
	assertSeconds(t, length, 86_399.143)
	if analysis.SessionLength.LearnedFrom != 2 {
		t.Errorf("learned from %d", analysis.SessionLength.LearnedFrom)
	}
}

func TestStatusAfterRenewingInPlace(t *testing.T) {
	status := statusOf(t, "renewal", "2026-09-11T12:00:00Z", defaultWarn)
	// Not the old countdown: the renewed session's own learned expiry.
	if status.State != Active || status.Session.StartKind != Renewal || status.Expiry.Source != FromSessionLength {
		t.Errorf("state %s, start %s, source %s", status.State, status.Session.StartKind, status.Expiry.Source)
	}
	assertDate(t, status.Expiry.Date, utc(t, "2026-09-12T07:31:41.839Z"))
}

func TestStatusDuringTheWarningBeforeRenewing(t *testing.T) {
	status := statusOf(t, "renewal", "2026-09-11T07:31:30Z", defaultWarn)
	if status.State != ExpiringSoon {
		t.Errorf("state %s", status.State)
	}
	assertDate(t, status.Expiry.Date, utc(t, "2026-09-11T07:36:26.959Z"))
}

func TestRotatedGzipFilesAreReadInOrder(t *testing.T) {
	analysis := analyzeFixture(t, "rotation", "2026-10-09T12:00:00Z")
	var names []string
	for _, file := range analysis.LogFiles {
		names = append(names, file.Name())
	}
	want := []string{"driver-2026-10-06.log.gz", "driver-2026-10-07.log.gz", "driver-2026-10-08.log.gz", "driver.log"}
	if !reflect.DeepEqual(names, want) {
		t.Errorf("files %v", names)
	}
	// The notice and close at the top of the 10-06 file belong to a session
	// whose sign-in rotated away, so they're ignored.
	starts := []string{"2026-10-06T07:52:45.811Z", "2026-10-07T06:18:43.685Z", "2026-10-08T07:42:23.386Z", "2026-10-09T07:55:35.444Z"}
	if len(analysis.Sessions) != len(starts) {
		t.Fatalf("%d sessions", len(analysis.Sessions))
	}
	for i, start := range starts {
		assertDate(t, analysis.Sessions[i].Start, utc(t, start))
	}
}

func TestSessionsSpanningRotatedFiles(t *testing.T) {
	analysis := analyzeFixture(t, "rotation", "2026-10-09T12:00:00Z")
	// Signed in in the 10-07 file, warned and closed in the 10-08 file.
	spanning := analysis.Sessions[1]
	length, _ := spanning.MeasuredLength()
	assertSeconds(t, length, 86_397.531)
	if analysis.Outcome(spanning) != OutcomeExpired {
		t.Errorf("outcome %s", analysis.Outcome(spanning))
	}
	// Median of the two measurable sessions.
	if analysis.SessionLength.LearnedFrom != 2 {
		t.Errorf("learned from %d", analysis.SessionLength.LearnedFrom)
	}
	assertSeconds(t, analysis.SessionLength.Duration, (86_397.531+86_399.234)/2)
	status := analysis.Status(defaultWarn)
	if status.State != Active {
		t.Errorf("state %s", status.State)
	}
	assertDate(t, status.Session.Start, utc(t, "2026-10-09T07:55:35.444Z"))
}

func TestSignInAfterDriverRestartWithoutClientClose(t *testing.T) {
	// 10-07 06:12 the driver restarts (reboot); the 06:18 login has no client
	// close before it but is still a new sign-in.
	analysis := analyzeFixture(t, "rotation", "2026-10-09T12:00:00Z")
	first := analysis.Sessions[0]
	if first.EndKind != DriverRestartedEnd || analysis.Outcome(first) != OutcomeInterrupted {
		t.Errorf("end %s, outcome %s", first.EndKind, analysis.Outcome(first))
	}
	assertDate(t, first.End, utc(t, "2026-10-07T06:12:29.811Z"))
	if analysis.Sessions[1].StartKind != SignIn {
		t.Errorf("start %s", analysis.Sessions[1].StartKind)
	}
}

func TestSigningOutOnANonZeroPort(t *testing.T) {
	// The client closes *:62973 and *:62956, not *:0, and the driver stops after.
	analysis := analyzeFixture(t, "signed-out", "2026-09-28T08:00:00Z")
	if len(analysis.Sessions) != 1 {
		t.Fatalf("%d sessions", len(analysis.Sessions))
	}
	session := analysis.Sessions[0]
	assertDate(t, session.End, utc(t, "2026-09-28T07:07:34.086Z"))
	if session.EndKind != ClientClosedEnd || analysis.Outcome(session) != OutcomeSignedOut || session.Reconnects != 1 {
		t.Errorf("end %s, outcome %s, reconnects %d", session.EndKind, analysis.Outcome(session), session.Reconnects)
	}
	if state := analysis.Status(defaultWarn).State; state != SignedOut {
		t.Errorf("state %s", state)
	}
}

func TestEmptyLogMeansNoSession(t *testing.T) {
	status := statusOf(t, "empty", "2026-10-10T12:00:00Z", defaultWarn)
	if status.State != NoSession || status.Session != nil || !status.SessionLength.IsFallback() {
		t.Errorf("status %+v", status)
	}
}

func TestUnknownFormatFailsLoudly(t *testing.T) {
	date := utc(t, "2026-10-10T12:00:00Z")
	_, err := New(fixture("unknown-format"), func() time.Time { return date }).Analyze()
	var parseErr *Error
	if !errors.As(err, &parseErr) || parseErr.Kind != UnrecognizedLine {
		t.Fatalf("expected an unrecognized line, got %v", err)
	}
	if parseErr.File != "driver.log" || parseErr.Line != 1 || !strings.HasPrefix(parseErr.Text, "2026-10-08 07:42:22,804 INFO") {
		t.Errorf("error %#v", parseErr)
	}
	if !strings.Contains(err.Error(), "doesn't match any known Appgate log format") {
		t.Errorf("message %s", err)
	}
}

func TestMissingLogDirectoryIsAnError(t *testing.T) {
	_, err := New(fixture("does-not-exist"), time.Now).Analyze()
	var dirErr *Error
	if !errors.As(err, &dirErr) || dirErr.Kind != LogDirectoryUnreadable {
		t.Errorf("got %v", err)
	}
}
