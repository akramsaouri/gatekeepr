package core

import (
	"testing"
	"time"
)

// Session rules on hand-built event sequences, for the cases the fixtures don't cover.

var sessionBase = time.Date(2026, 10, 10, 8, 0, 0, 0, time.UTC)

func at(hours float64) time.Time {
	return sessionBase.Add(time.Duration(hours * float64(time.Hour)))
}

func login(hours float64) Event { return Event{Date: at(hours), Kind: Login, Site: "AWS"} }
func event(hours float64, kind EventKind) Event {
	return Event{Date: at(hours), Kind: kind}
}
func notice(hours float64, left time.Duration) Event {
	return Event{Date: at(hours), Kind: RenewalNotification, TimeLeft: left}
}

func analysisOf(events []Event, nowHours float64) Analysis {
	return NewAnalysis(at(nowHours), nil, events)
}

func TestOneLoginPerSiteIsOneSignIn(t *testing.T) {
	sessions := buildSessions([]Event{login(0), {Date: at(0.0005), Kind: Login, Site: "GCP"}})
	if len(sessions) != 1 || sessions[0].Reconnects != 0 {
		t.Errorf("sessions %+v", sessions)
	}
}

func TestSigningOutEarly(t *testing.T) {
	result := analysisOf([]Event{login(0), event(2, ClientClosed)}, 3)
	if result.Outcome(result.Sessions[0]) != OutcomeSignedOut {
		t.Errorf("outcome %s", result.Outcome(result.Sessions[0]))
	}
	if status := result.Status(1800 * time.Second); status.State != SignedOut {
		t.Errorf("state %s", status.State)
	}
}

func TestNewControlConnectionWithoutCloseStartsANewSession(t *testing.T) {
	result := analysisOf([]Event{login(0), event(5, ClientConnected), event(5.001, Deploy), login(5.002)}, 6)
	if len(result.Sessions) != 2 {
		t.Fatalf("%d sessions", len(result.Sessions))
	}
	if result.Sessions[0].EndKind != ClientRestarted || result.Outcome(result.Sessions[0]) != OutcomeInterrupted {
		t.Errorf("end %s, outcome %s", result.Sessions[0].EndKind, result.Outcome(result.Sessions[0]))
	}
	assertDate(t, result.Sessions[1].Start, at(5.002))
}

func TestDeployWithoutACountdownIsNotARenewal(t *testing.T) {
	sessions := buildSessions([]Event{login(0), event(10, Deploy), login(10.001)})
	if len(sessions) != 1 || sessions[0].Reconnects != 1 {
		t.Errorf("sessions %+v", sessions)
	}
}

func TestDeployAfterTheCountdownRanOutIsNotARenewal(t *testing.T) {
	sessions := buildSessions([]Event{login(0), notice(23.9, 300*time.Second), event(24.5, Deploy)})
	if len(sessions) != 1 {
		t.Errorf("%d sessions", len(sessions))
	}
}

func TestDeployDuringTheCountdownRenewsInPlace(t *testing.T) {
	sessions := buildSessions([]Event{login(0), notice(23.95, 300*time.Second), event(23.96, Deploy)})
	if len(sessions) != 2 || sessions[0].EndKind != Renewed || sessions[1].StartKind != Renewal {
		t.Fatalf("sessions %+v", sessions)
	}
	assertDate(t, sessions[1].Start, at(23.96))
}

func TestNoticesBeforeTheFirstSignInAreIgnored(t *testing.T) {
	sessions := buildSessions([]Event{notice(0, 300*time.Second), event(0.1, ClientClosed), login(1)})
	if len(sessions) != 1 || sessions[0].FirstRenewalNotice != nil {
		t.Errorf("sessions %+v", sessions)
	}
}

func TestLengthIsTheMedianOfMeasuredSessions(t *testing.T) {
	session := func(start, noticeAfter float64) []Event {
		return []Event{
			login(start),
			notice(start+noticeAfter, 300*time.Second),
			event(start+noticeAfter+300.0/3600, ClientClosed),
		}
	}
	var events []Event
	for _, s := range [][2]float64{{0, 10}, {30, 12}, {60, 20}, {90, 22}} {
		events = append(events, session(s[0], s[1])...)
	}
	result := analysisOf(events, 200)
	if result.SessionLength.LearnedFrom != 4 {
		t.Errorf("learned from %d", result.SessionLength.LearnedFrom)
	}
	// Lengths 10h05, 12h05, 20h05, 22h05: the median is halfway between the middle two.
	assertSeconds(t, result.SessionLength.Duration, 16*3600+300)
}

func TestMeasurementUsesTheFirstNoticeTimeLeft(t *testing.T) {
	// Asleep through the first notices: the first one seen says 120 s left.
	sessions := buildSessions([]Event{login(0), notice(23.9, 120*time.Second)})
	length, ok := sessions[0].MeasuredLength()
	if !ok {
		t.Fatal("no measured length")
	}
	assertSeconds(t, length, 23.9*3600+120)
}

func TestNoSessionsAtAll(t *testing.T) {
	result := analysisOf([]Event{event(0, ClientClosed)}, 1)
	if len(result.Sessions) != 0 || result.Status(1800*time.Second).State != NoSession {
		t.Errorf("sessions %+v", result.Sessions)
	}
}

func TestEventsAfterNowAreIgnored(t *testing.T) {
	dir := writeFiles(t, map[string]string{"driver.log": loginLine + "\n"})
	before := utc(t, "2026-10-10T23:00:00Z")
	analysis, err := New(dir, func() time.Time { return before }).Analyze()
	if err != nil || len(analysis.Sessions) != 0 {
		t.Errorf("sessions %+v, error %v", analysis.Sessions, err)
	}
}
