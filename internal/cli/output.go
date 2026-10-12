package cli

import (
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/akramsaouri/gatekeepr/internal/core"
)

// statusText is what `gatekeepr` prints: the summary's heading, then its rows
// with the labels in a column.
func statusText(status core.Status, logDirectory string, loc *time.Location) string {
	summary := core.Summarize(status, logDirectory, loc)
	width := 0
	for _, row := range summary.Rows {
		width = max(width, utf8.RuneCountInString(row.Label))
	}
	lines := []string{summary.Heading}
	for _, row := range summary.Rows {
		lines = append(lines, "  "+pad(row.Label, width)+"  "+row.Value)
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
			end = core.FormatDate(session.End, loc)
		}
		length, ok := core.FormatMeasuredLength(session)
		if !ok {
			length = "-"
		}
		table = append(table, []string{
			core.FormatDate(session.Start, loc),
			how,
			end,
			core.FormatOutcome(analysis.Outcome(session)),
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
		"Session length: "+core.FormatSessionLength(analysis.SessionLength)+".",
		"Length is sign-in to Appgate's first expiry warning plus the warning's countdown; "+
			`"-" means no warning was seen.`)
	return strings.Join(lines, "\n")
}

func pad(s string, width int) string {
	return s + strings.Repeat(" ", max(0, width-utf8.RuneCountInString(s)))
}
