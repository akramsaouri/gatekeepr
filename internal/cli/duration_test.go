package cli

import (
	"testing"
	"time"
)

func TestDurationParse(t *testing.T) {
	for text, want := range map[string]time.Duration{
		"30m": 30 * time.Minute, "2h": 2 * time.Hour, "1h30m": 90 * time.Minute, "1H30M": 90 * time.Minute,
		"45s": 45 * time.Second, "1h30m15s": 5415 * time.Second, "90m": 90 * time.Minute, "0m": 0, "007m": 7 * time.Minute,
	} {
		if got, ok := parseDuration(text); !ok || got != want {
			t.Errorf("%q: got %v, %v", text, got, ok)
		}
	}
}

func TestDurationParseRejects(t *testing.T) {
	for _, text := range []string{"", "30", "m", "1m1h", "1h1h", "1.5h", "-5m", " 30m", "30m ", "1d", "h30m", "99999999999999999999h"} {
		if _, ok := parseDuration(text); ok {
			t.Errorf("%q parsed", text)
		}
	}
}

func TestDurationFormat(t *testing.T) {
	seconds := func(s float64) time.Duration { return time.Duration(s * float64(time.Second)) }
	for _, c := range []struct {
		d        time.Duration
		rounding rounding
		want     string
	}{
		{seconds(6*3600 + 8*60 + 59), roundDown, "6h08m"},
		{seconds(59*60 + 59), roundDown, "59m"},
		{seconds(59), roundDown, "<1m"},
		{0, roundDown, "0m"},
		{seconds(-90), roundDown, "0m"},
		{seconds(86_399.234), roundDown, "23h59m"},
		{seconds(86_399.234), roundNearest, "24h00m"},
		{seconds(29), roundNearest, "0m"},
		{seconds(30), roundNearest, "1m"},
	} {
		if got := formatDuration(c.d, c.rounding); got != c.want {
			t.Errorf("%v: got %s, want %s", c.d, got, c.want)
		}
	}
}
