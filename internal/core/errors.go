package core

import "fmt"

// ErrorKind says what stopped gatekeepr from giving an answer it can stand
// behind. The CLI maps every kind to exit code 3.
type ErrorKind int

const (
	// LogDirectoryUnreadable: the log directory is missing or can't be listed.
	LogDirectoryUnreadable ErrorKind = iota
	// NoLogFiles: the directory exists but holds no driver.log or
	// driver-YYYY-MM-DD.log.gz.
	NoLogFiles
	// LogFileUnreadable: a log file exists but can't be read or decompressed.
	LogFileUnreadable
	// UnrecognizedLine: a line doesn't look like any log line gatekeepr knows.
	// Appgate may have changed its log format, so gatekeepr refuses to guess.
	UnrecognizedLine
	// UnrecognizedEvent: a line looks session-related (a login, a renewal
	// notice, a close) but doesn't have the shape gatekeepr expects.
	UnrecognizedEvent
)

// Error is every failure gatekeepr reports. Which fields are set depends on Kind.
type Error struct {
	Kind ErrorKind
	// Path is the log directory, for LogDirectoryUnreadable and NoLogFiles.
	Path string
	// File is the log file's name, for the other kinds.
	File   string
	Line   int
	Text   string
	Reason string
}

func (e *Error) Error() string {
	switch e.Kind {
	case LogDirectoryUnreadable:
		return fmt.Sprintf("can't read the log directory %s: %s", e.Path, e.Reason)
	case NoLogFiles:
		return fmt.Sprintf("no driver.log or driver-YYYY-MM-DD.log.gz files in %s", e.Path)
	case LogFileUnreadable:
		return fmt.Sprintf("can't read %s: %s", e.File, e.Reason)
	case UnrecognizedLine:
		return fmt.Sprintf("%s:%d: this line doesn't match any known Appgate log format, "+
			"so gatekeepr won't guess. Line: %s", e.File, e.Line, excerpt(e.Text))
	default:
		return fmt.Sprintf("%s:%d: %s, so gatekeepr won't guess. Line: %s", e.File, e.Line, e.Reason, excerpt(e.Text))
	}
}

// excerpt cuts a line to 160 characters (grapheme clusters, as the Swift
// version counted them) and marks the cut with an ellipsis.
func excerpt(text string) string {
	if graphemeCount(text) <= 160 {
		return text
	}
	return graphemePrefix(text, 160) + "…"
}
