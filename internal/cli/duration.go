package cli

import (
	"fmt"
	"math"
	"strings"
	"time"
)

// parseDuration parses `30m`, `2h`, `1h30m`, `45s` or `1h30m15s`, in any
// case. Units must come in h, m, s order, each at most once. ok is false for
// anything else.
func parseDuration(text string) (time.Duration, bool) {
	rest := strings.ToLower(text)
	if rest == "" {
		return 0, false
	}
	units := []struct {
		unit byte
		size time.Duration
	}{{'h', time.Hour}, {'m', time.Minute}, {'s', time.Second}}
	var total time.Duration
	for rest != "" {
		digits := 0
		for digits < len(rest) && rest[digits] >= '0' && rest[digits] <= '9' {
			digits++
		}
		if digits == 0 || digits == len(rest) {
			return 0, false
		}
		unit := rest[digits]
		index := -1
		for i, u := range units {
			if u.unit == unit {
				index = i
				break
			}
		}
		if index < 0 {
			return 0, false
		}
		// Durations past time.Duration's ~292 years are refused rather than wrapped.
		limit := (math.MaxInt64 - total) / units[index].size
		var value time.Duration
		for _, c := range rest[:digits] {
			value = value*10 + time.Duration(c-'0')
			if value > limit {
				return 0, false
			}
		}
		total += value * units[index].size
		units = units[index+1:]
		rest = rest[digits+1:]
	}
	return total, true
}

// rounding picks how formatDuration turns seconds into minutes.
type rounding int

const (
	// roundDown never overstates time left.
	roundDown rounding = iota
	// roundNearest rounds half away from zero.
	roundNearest
)

// formatDuration gives `6h08m`, `45m`, `<1m` or `0m`.
func formatDuration(d time.Duration, r rounding) string {
	if d < 0 {
		d = 0
	}
	var minutes int64
	if r == roundDown {
		minutes = int64(d / time.Minute)
	} else {
		minutes = int64((d + 30*time.Second) / time.Minute)
	}
	if minutes == 0 {
		if d > 0 && r == roundDown {
			return "<1m"
		}
		return "0m"
	}
	if hours := minutes / 60; hours > 0 {
		return fmt.Sprintf("%dh%02dm", hours, minutes%60)
	}
	return fmt.Sprintf("%dm", minutes)
}
