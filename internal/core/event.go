package core

import "time"

// EventKind is a log line that matters for working out sessions. Everything
// else in the driver log (routes, DNS, status JSON, periodic update-tokens)
// is noise.
type EventKind int

const (
	// Login: the client sent a login to a site. One per site, so a sign-in
	// shows up as two logins a second or two apart. Gateway reconnects send a
	// fresh login too.
	Login EventKind = iota
	// ClientClosed: the Appgate client closed its control connection: the
	// user signed out, or the session expired and the client tore it down.
	ClientClosed
	// ClientConnected: the Appgate client opened a control connection to the
	// driver. Every sign-in starts with one; a session can't survive it.
	ClientConnected
	// DriverRestarted: the driver's event loop started or stopped (reboot,
	// driver restart). Any session from before is gone.
	DriverRestarted
	// Deploy: the client pushed a new deployment to the driver. Right after a
	// renewal notification this is the user renewing the session in place.
	Deploy
	// RenewalNotification: the gateway's "your session ends in timeLeft
	// seconds" warning, repeated every minute until expiry.
	RenewalNotification
)

// Event is one session-related log line.
type Event struct {
	Date time.Time
	Kind EventKind
	// Site is the site a Login went to.
	Site string
	// TimeLeft is a RenewalNotification's countdown.
	TimeLeft time.Duration
	// File and Line say where the line came from, for error messages.
	File string
	Line int
}
