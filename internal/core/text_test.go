package core

import (
	"strings"
	"testing"
	"time"
)

func TestDurationParse(t *testing.T) {
	for text, want := range map[string]time.Duration{
		"30m": 30 * time.Minute, "2h": 2 * time.Hour, "1h30m": 90 * time.Minute, "1H30M": 90 * time.Minute,
		"45s": 45 * time.Second, "1h30m15s": 5415 * time.Second, "90m": 90 * time.Minute, "0m": 0, "007m": 7 * time.Minute,
	} {
		if got, ok := ParseDuration(text); !ok || got != want {
			t.Errorf("%q: got %v, %v", text, got, ok)
		}
	}
}

func TestDurationParseRejects(t *testing.T) {
	for _, text := range []string{"", "30", "m", "1m1h", "1h1h", "1.5h", "-5m", " 30m", "30m ", "1d", "h30m", "99999999999999999999h"} {
		if _, ok := ParseDuration(text); ok {
			t.Errorf("%q parsed", text)
		}
	}
}

func TestDurationFormat(t *testing.T) {
	seconds := func(s float64) time.Duration { return time.Duration(s * float64(time.Second)) }
	for _, c := range []struct {
		d        time.Duration
		rounding Rounding
		want     string
	}{
		{seconds(6*3600 + 8*60 + 59), RoundDown, "6h08m"},
		{seconds(59*60 + 59), RoundDown, "59m"},
		{seconds(59), RoundDown, "<1m"},
		{0, RoundDown, "0m"},
		{seconds(-90), RoundDown, "0m"},
		{seconds(86_399.234), RoundDown, "23h59m"},
		{seconds(86_399.234), RoundNearest, "24h00m"},
		{seconds(29), RoundNearest, "0m"},
		{seconds(30), RoundNearest, "1m"},
	} {
		if got := FormatDuration(c.d, c.rounding); got != c.want {
			t.Errorf("%v: got %s, want %s", c.d, got, c.want)
		}
	}
}

func TestRepairUTF8ReplacesEachMaximalSubpart(t *testing.T) {
	// One U+FFFD per maximal subpart, as Swift's String(decoding:as:) does.
	got := repairUTF8([]byte("abc\xe2\x82 def\xf0\x9f\x98 ghi\xed\xa0\x80 jkl\xc0\xaf mno\xff\xfe é\U0001F600"))
	want := "abc� def� ghi��� jkl�� mno�� é\U0001F600"
	if got != want {
		t.Errorf("got %q\nwant %q", got, want)
	}
}

func TestExcerptCountsCharacters(t *testing.T) {
	short := strings.Repeat("x", 160)
	if excerpt(short) != short {
		t.Error("160 characters shouldn't be cut")
	}
	// e + U+0301 is one character, as the Swift version counted.
	combining := strings.Repeat("x", 158) + strings.Repeat("é", 3) + strings.Repeat("y", 10)
	if got, want := excerpt(combining), strings.Repeat("x", 158)+"éé…"; got != want {
		t.Errorf("got %q", got)
	}
	flags := strings.Repeat("x", 159) + "🇸🇪🇸🇪"
	if got, want := excerpt(flags), strings.Repeat("x", 159)+"🇸🇪…"; got != want {
		t.Errorf("got %q", got)
	}
}

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
	if got := ErrorReport("boom"); got != want {
		t.Errorf("got\n%s", got)
	}
}

func TestEmptyHistoryReport(t *testing.T) {
	analysis := NewAnalysis(time.Date(2026, 10, 10, 12, 0, 0, 0, time.UTC), nil, nil)
	got := HistoryReport(analysis, time.UTC)
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
