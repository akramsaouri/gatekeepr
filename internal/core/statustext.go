package core

import (
	"fmt"
	"time"
)

// ShortError is what `gatekeepr --short` prints when the logs can't be read or parsed.
const ShortError = "error"

// ShortStatus is `gatekeepr --short`: `6h08m`, `expired`, `signed out` or `no session`.
func ShortStatus(status Status) string {
	switch status.State {
	case Active, ExpiringSoon:
		left, _ := status.TimeLeft()
		return FormatDuration(left, RoundDown)
	case Expired:
		return "expired"
	case SignedOut:
		return "signed out"
	}
	return "no session"
}

// SummaryRow is one labelled line of a Summary.
type SummaryRow struct {
	Label string
	Value string
}

// Summary is a heading and labelled rows: what `gatekeepr` prints.
type Summary struct {
	Heading string
	Rows    []SummaryRow
}

// Summarize words a status. Times are shown in loc.
func Summarize(status Status, logDirectory string, loc *time.Location) Summary {
	if status.Session == nil || status.Expiry == nil {
		return Summary{Heading: fmt.Sprintf("No Appgate session found in %s.", logDirectory)}
	}
	session, expiry := *status.Session, *status.Expiry
	date := func(t time.Time) string { return FormatDate(t, loc) }
	started := "Signed in"
	if session.StartKind == Renewal {
		started = "Renewed"
	}
	length := FormatSessionLength(status.SessionLength)

	switch status.State {
	case Active, ExpiringSoon:
		heading := "Appgate session active"
		if status.State == ExpiringSoon {
			heading = fmt.Sprintf("Appgate session expires soon (warning at %s)", FormatDuration(status.WarnThreshold, RoundDown))
		}
		source := ""
		if expiry.Source == FromRenewalNotification {
			source = ", per Appgate's expiry warning"
		}
		left, _ := status.TimeLeft()
		return Summary{Heading: heading, Rows: []SummaryRow{
			{started, date(session.Start)},
			{"Expires", date(expiry.Date) + source},
			{"Time left", FormatDuration(left, RoundDown)},
			{"Length", length},
		}}
	case Expired:
		ago := FormatDuration(status.Now.Sub(expiry.Date), RoundDown)
		return Summary{Heading: "Appgate session expired", Rows: []SummaryRow{
			{started, date(session.Start)},
			{"Expired", fmt.Sprintf("%s (%s ago)", date(expiry.Date), ago)},
			{"Length", length},
		}}
	default: // SignedOut, which is always a closed session
		reason := "signed out"
		if status.Outcome == OutcomeInterrupted {
			reason = "the Appgate driver restarted"
			if session.EndKind == ClientRestarted {
				reason = "the Appgate client restarted"
			}
		}
		return Summary{Heading: "Not signed in to Appgate", Rows: []SummaryRow{
			{"Last session", date(session.Start)},
			{"Ended", fmt.Sprintf("%s (%s)", date(session.End), reason)},
		}}
	}
}

// FormatSessionLength gives `24h00m, the median of 17 measured sessions`.
func FormatSessionLength(length SessionLength) string {
	duration := FormatDuration(length.Duration, RoundNearest)
	switch length.LearnedFrom {
	case 0:
		return duration + " (default, no measured sessions yet)"
	case 1:
		return duration + ", measured from 1 session"
	}
	return fmt.Sprintf("%s, the median of %d measured sessions", duration, length.LearnedFrom)
}

// FormatMeasuredLength is a session's measured length (`24h00m`); ok is false
// if no renewal notice was seen.
func FormatMeasuredLength(session Session) (string, bool) {
	length, ok := session.MeasuredLength()
	if !ok {
		return "", false
	}
	return FormatDuration(length, RoundNearest), true
}

func FormatOutcome(outcome Outcome) string {
	if outcome == OutcomeSignedOut {
		return "signed out"
	}
	return string(outcome)
}

// FormatDate gives `Sun 11 Oct 01:24`.
func FormatDate(t time.Time, loc *time.Location) string {
	return t.In(loc).Format("Mon 2 Jan 15:04")
}
