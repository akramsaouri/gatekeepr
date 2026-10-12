package core

import "time"

// SessionStart is how a session began.
type SessionStart string

const (
	// SignIn: a login after the client closed, the client or driver
	// restarted, or the first login in the log history.
	SignIn SessionStart = "signIn"
	// Renewal: the user renewed from the expiry warning: a deploy arrived
	// while renewal notifications were counting down, with no close or login.
	Renewal SessionStart = "renewal"
)

// SessionEnd is what ended a session.
type SessionEnd string

const (
	// ClientClosedEnd: the client closed its control connection (sign-out or expiry).
	ClientClosedEnd SessionEnd = "clientClosed"
	// ClientRestarted: the client opened a new control connection without
	// closing the old one.
	ClientRestarted SessionEnd = "clientRestarted"
	// DriverRestartedEnd: the driver's event loop stopped or started (reboot,
	// driver restart).
	DriverRestartedEnd SessionEnd = "driverRestarted"
	// Renewed: renewed in place; the next session starts at the same moment.
	Renewed SessionEnd = "renewed"
)

// Outcome is how a session turned out.
type Outcome string

const (
	OutcomeActive    Outcome = "active"
	OutcomeExpired   Outcome = "expired"
	OutcomeSignedOut Outcome = "signedOut"
	OutcomeRenewed   Outcome = "renewed"
	// OutcomeInterrupted: ended early by a client or driver restart.
	OutcomeInterrupted Outcome = "interrupted"
)

// RenewalNotice is a token-renewal-notification: the gateway saying the
// session ends in TimeLeft.
type RenewalNotice struct {
	Date     time.Time
	TimeLeft time.Duration
}

func (n RenewalNotice) Expiry() time.Time { return n.Date.Add(n.TimeLeft) }

// Session is one Appgate session, from sign-in (or in-place renewal) to
// whatever ended it.
type Session struct {
	Start     time.Time
	StartKind SessionStart
	// End and EndKind are zero while the session is open.
	End                time.Time
	EndKind            SessionEnd
	FirstRenewalNotice *RenewalNotice
	LastRenewalNotice  *RenewalNotice
	// Reconnects counts gateway reconnects during the session. Each one sends
	// a new login, and none of them restart the session.
	Reconnects int
}

// IsOpen is true while the session is still going as far as the log knows.
func (s Session) IsOpen() bool { return s.EndKind == "" }

// MeasuredLength is start to first renewal notice, plus that notice's
// timeLeft: how long the gateway gave this session. ok is false if no notice
// was seen.
func (s Session) MeasuredLength() (time.Duration, bool) {
	if s.FirstRenewalNotice == nil {
		return 0, false
	}
	return s.FirstRenewalNotice.Expiry().Sub(s.Start), true
}

// loginBurst: logins closer together than this are one burst. A sign-in or
// reconnect sends one login per site within a second or two.
const loginBurst = 10 * time.Second

// buildSessions splits events into sessions, oldest first. Only the last
// one can be open.
func buildSessions(events []Event) []Session {
	var sessions []Session
	var open *Session
	var lastLogin *time.Time

	closeOpen := func(date time.Time, kind SessionEnd) {
		if open == nil {
			return
		}
		open.End = date
		open.EndKind = kind
		sessions = append(sessions, *open)
		open = nil
	}

	for _, event := range events {
		switch event.Kind {
		case Login:
			if open != nil {
				if lastLogin != nil && event.Date.Sub(*lastLogin) > loginBurst {
					open.Reconnects++
				}
			} else {
				open = &Session{Start: event.Date, StartKind: SignIn}
			}
			date := event.Date
			lastLogin = &date
		case ClientClosed:
			closeOpen(event.Date, ClientClosedEnd)
		case ClientConnected:
			closeOpen(event.Date, ClientRestarted)
		case DriverRestarted:
			closeOpen(event.Date, DriverRestartedEnd)
		case Deploy:
			// Outside the countdown a deploy is a reconnect or token refresh.
			if open != nil && open.LastRenewalNotice != nil && !event.Date.After(open.LastRenewalNotice.Expiry()) {
				closeOpen(event.Date, Renewed)
				open = &Session{Start: event.Date, StartKind: Renewal}
			}
		case RenewalNotification:
			// Notices from before the first sign-in in the history have no session.
			if open == nil {
				continue
			}
			notice := RenewalNotice{Date: event.Date, TimeLeft: event.TimeLeft}
			if open.FirstRenewalNotice == nil {
				first := notice
				open.FirstRenewalNotice = &first
			}
			last := notice
			open.LastRenewalNotice = &last
		}
	}
	if open != nil {
		sessions = append(sessions, *open)
	}
	return sessions
}
