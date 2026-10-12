package cli

import (
	"strings"
	"testing"
	"time"

	"github.com/akramsaouri/gatekeepr/internal/core"
)

func TestJSONStringEscaping(t *testing.T) {
	// What NSJSONSerialization wrote for the Swift version's error output.
	var b strings.Builder
	writeJSONString(&b, "tab\t\"q\" back\\ /slash \x01\x07\b\x0b\f\x1b\x1f\x7f   é😀\n\r")
	want := `"tab\t\"q\" back\\ /slash \u0001\u0007\b\u000b\f\u001b\u001f` + "\x7f   é😀" + `\n\r"`
	if b.String() != want {
		t.Errorf("got  %s\nwant %s", b.String(), want)
	}
}

func TestErrorReport(t *testing.T) {
	want := "{\n  \"error\" : \"boom\",\n  \"exitCode\" : 3,\n  \"schemaVersion\" : 1,\n  \"state\" : \"error\"\n}"
	if got := errorReport("boom"); got != want {
		t.Errorf("got\n%s", got)
	}
}

func TestEmptyHistoryReport(t *testing.T) {
	analysis := core.NewAnalysis(time.Date(2026, 10, 10, 12, 0, 0, 0, time.UTC), nil, nil)
	got := historyReport(analysis, time.UTC)
	if !strings.Contains(got, "\"sessions\" : [\n\n  ]") || !strings.Contains(got, "\"sessionLengthSource\" : \"default\"") {
		t.Errorf("got\n%s", got)
	}
}

func TestSecondsRounding(t *testing.T) {
	if got := floorSeconds(-500 * time.Millisecond); got != -1 {
		t.Errorf("floor(-0.5s) = %d", got)
	}
	if got := floorSeconds(1999 * time.Millisecond); got != 1 {
		t.Errorf("floor(1.999s) = %d", got)
	}
	if got := roundSeconds(86_398500 * time.Millisecond); got != 86_399 {
		t.Errorf("round(86398.5s) = %d", got)
	}
}
