package cli

import (
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/akramsaouri/gatekeepr/internal/core"
)

// shortError is what `gatekeepr --short` prints when the logs can't be read or parsed.
const shortError = "error"

// shortStatus is `gatekeepr --short`: `6h08m`, `expired`, `signed out` or `no session`.
func shortStatus(status core.Status) string {
	switch status.State {
	case core.Active, core.ExpiringSoon:
		left, _ := status.TimeLeft()
		return formatDuration(left, roundDown)
	case core.Expired:
		return "expired"
	case core.SignedOut:
		return "signed out"
	}
	return "no session"
}

// statusText is what `gatekeepr` prints: a heading, then labelled rows. Times
// are shown in loc.
func statusText(status core.Status, logDirectory string, loc *time.Location) string {
	if status.Session == nil || status.Expiry == nil {
		return fmt.Sprintf("No Appgate session found in %s.", logDirectory)
	}
	session, expiry := *status.Session, *status.Expiry
	date := func(t time.Time) string { return formatDate(t, loc) }
	started := "Signed in"
	if session.StartKind == core.Renewal {
		started = "Renewed"
	}
	length := formatSessionLength(status.SessionLength)

	switch status.State {
	case core.Active, core.ExpiringSoon:
		heading := "Appgate session active"
		if status.State == core.ExpiringSoon {
			heading = fmt.Sprintf("Appgate session expires soon (warning at %s)", formatDuration(status.WarnThreshold, roundDown))
		}
		source := ""
		if expiry.Source == core.FromRenewalNotification {
			source = ", per Appgate's expiry warning"
		}
		left, _ := status.TimeLeft()
		return labelled(heading, [][2]string{
			{started, date(session.Start)},
			{"Expires", date(expiry.Date) + source},
			{"Time left", formatDuration(left, roundDown)},
			{"Length", length},
		})
	case core.Expired:
		ago := formatDuration(status.Now.Sub(expiry.Date), roundDown)
		return labelled("Appgate session expired", [][2]string{
			{started, date(session.Start)},
			{"Expired", fmt.Sprintf("%s (%s ago)", date(expiry.Date), ago)},
			{"Length", length},
		})
	default: // SignedOut, which is always a closed session
		reason := "signed out"
		if status.Outcome == core.OutcomeInterrupted {
			reason = "the Appgate driver restarted"
			if session.EndKind == core.ClientRestarted {
				reason = "the Appgate client restarted"
			}
		}
		return labelled("Not signed in to Appgate", [][2]string{
			{"Last session", date(session.Start)},
			{"Ended", fmt.Sprintf("%s (%s)", date(session.End), reason)},
		})
	}
}

// labelled is a heading, then each label and value with the labels in a column.
func labelled(heading string, rows [][2]string) string {
	width := 0
	for _, row := range rows {
		width = max(width, utf8.RuneCountInString(row[0]))
	}
	lines := []string{heading}
	for _, row := range rows {
		lines = append(lines, "  "+pad(row[0], width)+"  "+row[1])
	}
	return strings.Join(lines, "\n")
}

// historyText is `gatekeepr history`: a table of sessions, oldest first.
func historyText(analysis core.Analysis, logDirectory string, loc *time.Location) string {
	if len(analysis.Sessions) == 0 {
		return fmt.Sprintf("No Appgate sessions found in %s.", logDirectory)
	}
	table := [][]string{{"Start", "How", "End", "Outcome", "Length", "Reconnects"}}
	for _, session := range analysis.Sessions {
		how := "sign-in"
		if session.StartKind == core.Renewal {
			how = "renewal"
		}
		end := "-"
		if !session.IsOpen() {
			end = formatDate(session.End, loc)
		}
		outcome := analysis.Outcome(session)
		outcomeText := string(outcome)
		if outcome == core.OutcomeSignedOut {
			outcomeText = "signed out"
		}
		length := "-"
		if measured, ok := session.MeasuredLength(); ok {
			length = formatDuration(measured, roundNearest)
		}
		table = append(table, []string{
			formatDate(session.Start, loc),
			how,
			end,
			outcomeText,
			length,
			fmt.Sprint(session.Reconnects),
		})
	}
	widths := make([]int, len(table[0]))
	for _, row := range table {
		for column, cell := range row {
			widths[column] = max(widths[column], utf8.RuneCountInString(cell))
		}
	}
	var lines []string
	for _, row := range table {
		cells := make([]string, len(row))
		for column, cell := range row {
			cells[column] = pad(cell, widths[column])
		}
		lines = append(lines, strings.Trim(strings.Join(cells, "  "), " \t"))
	}
	lines = append(lines, "",
		"Session length: "+formatSessionLength(analysis.SessionLength)+".",
		"Length is sign-in to Appgate's first expiry warning plus the warning's countdown; "+
			`"-" means no warning was seen.`)
	return strings.Join(lines, "\n")
}

// formatSessionLength gives `24h00m, the median of 17 measured sessions`.
func formatSessionLength(length core.SessionLength) string {
	duration := formatDuration(length.Duration, roundNearest)
	switch length.LearnedFrom {
	case 0:
		return duration + " (default, no measured sessions yet)"
	case 1:
		return duration + ", measured from 1 session"
	}
	return fmt.Sprintf("%s, the median of %d measured sessions", duration, length.LearnedFrom)
}

// formatDate gives `Sun 11 Oct 01:24`.
func formatDate(t time.Time, loc *time.Location) string {
	return t.In(loc).Format("Mon 2 Jan 15:04")
}

func pad(s string, width int) string {
	return s + strings.Repeat(" ", max(0, width-utf8.RuneCountInString(s)))
}
