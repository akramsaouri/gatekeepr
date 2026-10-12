package core

import (
	"strings"
	"unicode"
	"unicode/utf8"
)

// repairUTF8 replaces each invalid sequence with U+FFFD, one per maximal
// subpart (the Unicode-recommended practice, and what Swift's
// String(decoding:as:) does), so error excerpts match the Swift version.
func repairUTF8(data []byte) string {
	if utf8.Valid(data) {
		return string(data)
	}
	var b strings.Builder
	b.Grow(len(data))
	for i := 0; i < len(data); {
		r, size := utf8.DecodeRune(data[i:])
		if r != utf8.RuneError || size > 1 {
			b.Write(data[i : i+size])
			i += size
			continue
		}
		b.WriteRune(utf8.RuneError)
		i += maximalSubpart(data[i:])
	}
	return b.String()
}

// maximalSubpart is the length of the invalid sequence at the start of data:
// its lead byte plus the continuation bytes that could still have completed it.
func maximalSubpart(data []byte) int {
	lead := data[0]
	need, lo, hi := 0, byte(0x80), byte(0xBF)
	switch {
	case lead >= 0xC2 && lead <= 0xDF:
		need = 1
	case lead == 0xE0:
		need, lo = 2, 0xA0
	case lead == 0xED:
		need, hi = 2, 0x9F
	case lead >= 0xE1 && lead <= 0xEF:
		need = 2
	case lead == 0xF0:
		need, lo = 3, 0x90
	case lead == 0xF4:
		need, hi = 3, 0x8F
	case lead >= 0xF1 && lead <= 0xF3:
		need = 3
	}
	n := 1
	for k := 0; k < need && n < len(data); k++ {
		c := data[n]
		if k == 0 && (c < lo || c > hi) || k > 0 && (c < 0x80 || c > 0xBF) {
			break
		}
		n++
	}
	return n
}

// graphemeStarts reports, for each rune of s, whether it starts a new
// user-perceived character. It covers what log lines can plausibly hold:
// combining marks, emoji modifiers and ZWJ sequences, flags, and CR LF.
func graphemeStarts(s string) []bool {
	var starts []bool
	var prev rune
	regional := 0
	first := true
	for _, r := range s {
		start := true
		switch {
		case first:
		case prev == '\r' && r == '\n':
			start = false
		case unicode.In(r, unicode.Mn, unicode.Me, unicode.Mc), r == 0x200D:
			start = false
		case r >= 0x1F3FB && r <= 0x1F3FF:
			start = false
		case prev == 0x200D && unicode.Is(unicode.So, r):
			start = false
		case isRegionalIndicator(r) && isRegionalIndicator(prev) && regional%2 == 1:
			start = false
		}
		if isRegionalIndicator(r) {
			regional++
		} else {
			regional = 0
		}
		starts = append(starts, start)
		prev = r
		first = false
	}
	return starts
}

func isRegionalIndicator(r rune) bool { return r >= 0x1F1E6 && r <= 0x1F1FF }

func graphemeCount(s string) int {
	count := 0
	for _, start := range graphemeStarts(s) {
		if start {
			count++
		}
	}
	return count
}

// graphemePrefix is the first n user-perceived characters of s.
func graphemePrefix(s string, n int) string {
	starts := graphemeStarts(s)
	seen, index := 0, 0
	for offset := range s {
		if starts[index] {
			if seen == n {
				return s[:offset]
			}
			seen++
		}
		index++
	}
	return s
}

// isBlank is true when every character is whitespace (or there are none).
func isBlank(s string) bool {
	for _, r := range s {
		if !unicode.IsSpace(r) {
			return false
		}
	}
	return true
}
