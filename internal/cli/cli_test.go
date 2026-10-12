package cli

import (
	"testing"
)

// Most of the command line is pinned by the golden files in testdata/golden;
// these cover the pieces underneath.

func TestWrap(t *testing.T) {
	for _, c := range []struct {
		text            string
		columns, indent int
		want            string
	}{
		{"one two three", 80, 0, "one two three"},
		{"one two three", 8, 0, "one two\nthree"},
		{"one two three", 10, 2, "  one two\n  three"},
		{"a\n\nb", 80, 0, "a\n\nb"},
		{"averyveryverylongword next", 8, 0, "averyveryverylongword\nnext"},
		{"anything", 20, 26, ""},
	} {
		if got := wrap(c.text, c.columns, c.indent); got != c.want {
			t.Errorf("wrap(%q, %d, %d) = %q, want %q", c.text, c.columns, c.indent, got, c.want)
		}
	}
}

func TestEditDistance(t *testing.T) {
	for _, c := range []struct {
		a, b string
		want int
	}{
		{"--json", "--json", 0}, {"--jsno", "--json", 2}, {"--warn", "--json", 3}, {"", "abc", 3}, {"--s", "--json", 3},
	} {
		if got := editDistance(c.a, c.b); got != c.want {
			t.Errorf("editDistance(%q, %q) = %d, want %d", c.a, c.b, got, c.want)
		}
	}
}

func TestTerminalColumnsPrefersCOLUMNS(t *testing.T) {
	t.Setenv("COLUMNS", "123")
	if got := terminalColumns(); got != 123 {
		t.Errorf("got %d", got)
	}
	t.Setenv("COLUMNS", "wide")
	if got := terminalColumns(); got <= 0 {
		t.Errorf("got %d", got)
	}
}

func TestSplitArguments(t *testing.T) {
	split, err := splitArguments([]string{"--warn=5m", "-hx", "-", "--", "--json"})
	if err != nil {
		t.Fatal(err)
	}
	want := []element{
		{kind: optionElement, input: 0, sub: -1, name: name{longName, "warn"}, value: "5m", hasValue: true},
		{kind: optionElement, input: 1, sub: -1, name: name{singleDashName, "hx"}},
		{kind: optionElement, input: 1, sub: 0, name: name{shortName, "h"}},
		{kind: optionElement, input: 1, sub: 1, name: name{shortName, "x"}},
		{kind: valueElement, input: 2, sub: -1, text: "-"},
		{kind: terminatorElement, input: 3, sub: -1},
		{kind: valueElement, input: 4, sub: -1, text: "--json"},
	}
	if len(split) != len(want) {
		t.Fatalf("got %+v", split)
	}
	for i := range want {
		if split[i] != want[i] {
			t.Errorf("element %d: got %+v, want %+v", i, split[i], want[i])
		}
	}
}
