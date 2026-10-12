package core

import (
	"sort"
	"time"
)

// FallbackSessionLength is used when no session in the history has a renewal
// notice to measure.
const FallbackSessionLength = 24 * time.Hour

// SessionLength is how long a session lasts, learned from the sessions in the
// log history.
type SessionLength struct {
	Duration time.Duration
	// LearnedFrom is how many sessions the median was taken over; 0 means
	// FallbackSessionLength.
	LearnedFrom int
}

func (l SessionLength) IsFallback() bool { return l.LearnedFrom == 0 }

// learnSessionLength is the median measured length, or 24h when nothing could
// be measured.
func learnSessionLength(sessions []Session) SessionLength {
	var lengths []time.Duration
	for _, session := range sessions {
		if length, ok := session.MeasuredLength(); ok {
			lengths = append(lengths, length)
		}
	}
	if len(lengths) == 0 {
		return SessionLength{Duration: FallbackSessionLength}
	}
	sort.Slice(lengths, func(i, j int) bool { return lengths[i] < lengths[j] })
	middle := len(lengths) / 2
	median := lengths[middle]
	if len(lengths)%2 == 0 {
		median = (lengths[middle-1] + lengths[middle]) / 2
	}
	return SessionLength{Duration: median, LearnedFrom: len(lengths)}
}

// ExpirySource says where an expiry came from.
type ExpirySource string

const (
	// FromSessionLength: session start plus the learned (or default) session length.
	FromSessionLength ExpirySource = "sessionLength"
	// FromRenewalNotification: the gateway's own countdown: the latest
	// renewal notice's time plus its timeLeft.
	FromRenewalNotification ExpirySource = "renewalNotification"
)

type Expiry struct {
	Date   time.Time
	Source ExpirySource
}

// State is where the current session stands.
type State string

const (
	Active State = "active"
	// ExpiringSoon: signed in, with no more than the warn threshold left.
	ExpiringSoon State = "expiringSoon"
	Expired      State = "expired"
	SignedOut    State = "signedOut"
	// NoSession: no session anywhere in the log history.
	NoSession State = "noSession"
)

// ExitCode is 0 ok · 1 within the warn window · 2 expired or not signed in.
func (s State) ExitCode() int {
	switch s {
	case Active:
		return 0
	case ExpiringSoon:
		return 1
	}
	return 2
}

// Status is where the current session stands at one moment.
type Status struct {
	State State
	Now   time.Time
	// Session is the open session, or the most recent one when signed out.
	// Nil when there are none.
	Session       *Session
	Expiry        *Expiry
	WarnThreshold time.Duration
	SessionLength SessionLength
}

// TimeLeft is negative once expired; ok is false when there's no session.
func (s Status) TimeLeft() (time.Duration, bool) {
	if s.Expiry == nil {
		return 0, false
	}
	return s.Expiry.Date.Sub(s.Now), true
}

// expiryTolerance: a client close this close to the expected expiry counts
// as the session expiring.
const expiryTolerance = 120 * time.Second

// Analysis is the log history read at one moment: sessions, the learned
// session length, and from those, the status of the current session.
type Analysis struct {
	Now      time.Time
	LogFiles []LogFile
	// Sessions are oldest first. Only the last one can be open.
	Sessions      []Session
	SessionLength SessionLength
}

func NewAnalysis(now time.Time, logFiles []LogFile, events []Event) Analysis {
	sessions := buildSessions(events)
	return Analysis{Now: now, LogFiles: logFiles, Sessions: sessions, SessionLength: learnSessionLength(sessions)}
}

// Expiry of a session: a renewal notice in the session wins over the timing model.
func (a Analysis) Expiry(session Session) Expiry {
	if notice := session.LastRenewalNotice; notice != nil {
		return Expiry{Date: notice.Expiry(), Source: FromRenewalNotification}
	}
	return Expiry{Date: session.Start.Add(a.SessionLength.Duration), Source: FromSessionLength}
}

func (a Analysis) Outcome(session Session) Outcome {
	expiry := a.Expiry(session).Date
	if session.IsOpen() {
		if !a.Now.Before(expiry) {
			return OutcomeExpired
		}
		return OutcomeActive
	}
	if session.EndKind == Renewed {
		return OutcomeRenewed
	}
	if !session.End.Before(expiry.Add(-expiryTolerance)) {
		return OutcomeExpired
	}
	if session.EndKind == ClientClosedEnd {
		return OutcomeSignedOut
	}
	return OutcomeInterrupted
}

func (a Analysis) Status(warnThreshold time.Duration) Status {
	status := Status{Now: a.Now, WarnThreshold: warnThreshold, SessionLength: a.SessionLength}
	if len(a.Sessions) == 0 {
		status.State = NoSession
		return status
	}
	session := a.Sessions[len(a.Sessions)-1]
	expiry := a.Expiry(session)
	switch a.Outcome(session) {
	case OutcomeActive:
		if expiry.Date.Sub(a.Now) <= warnThreshold {
			status.State = ExpiringSoon
		} else {
			status.State = Active
		}
	case OutcomeExpired:
		status.State = Expired
	default:
		status.State = SignedOut
	}
	status.Session = &session
	status.Expiry = &expiry
	return status
}

// Gatekeepr reads the driver logs and works out the session.
type Gatekeepr struct {
	LogDirectory LogDirectory
	// Clock is the current time. Log lines after it are ignored, so tests can
	// ask "what did the log say at 9:00?".
	Clock func() time.Time
}

func New(logDirectory string, clock func() time.Time) Gatekeepr {
	return Gatekeepr{LogDirectory: LogDirectory{Path: logDirectory}, Clock: clock}
}

func (g Gatekeepr) Analyze() (Analysis, error) {
	now := g.Clock()
	files, err := g.LogDirectory.Files()
	if err != nil {
		return Analysis{}, err
	}
	var events []Event
	for _, file := range files {
		text, err := g.LogDirectory.Text(file)
		if err != nil {
			return Analysis{}, err
		}
		fileEvents, err := ParseEvents(text, file.Name())
		if err != nil {
			return Analysis{}, err
		}
		events = append(events, fileEvents...)
	}
	// Files are already oldest first; sorting by time (keeping file order for
	// ties) also copes with rotated files that overlap.
	kept := events[:0]
	for _, event := range events {
		if !event.Date.After(now) {
			kept = append(kept, event)
		}
	}
	sort.SliceStable(kept, func(i, j int) bool { return kept[i].Date.Before(kept[j].Date) })
	return NewAnalysis(now, files, kept), nil
}

func (g Gatekeepr) Status(warnThreshold time.Duration) (Status, error) {
	analysis, err := g.Analyze()
	if err != nil {
		return Status{}, err
	}
	return analysis.Status(warnThreshold), nil
}
