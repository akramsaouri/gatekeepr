package core

import (
	"strings"
	"testing"
)

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
