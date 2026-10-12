package main

import (
	"bytes"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/akramsaouri/gatekeepr/internal/cli"
)

// The golden files in testdata/golden pin what gatekeepr prints and exits
// with, case by case. They were first captured from the Swift version
// (v0.2.1); see testdata/golden/README.md. Text output, help, usage errors
// and exit codes must match them byte for byte. JSON output is the v1
// contract in docs/JSON.md, and must also be the Swift JSON plus the fields
// schema v1 added, nothing else.
//
//	go test -run TestGolden -update   # rewrite the stdout, stderr and exit of every case

var update = flag.Bool("update", false, "rewrite the golden files with the current output")

// addedInV1 are the JSON fields schema v1 added to the Swift output.
var addedInV1 = regexp.MustCompile(`(?m)^ *"(schemaVersion|sessionLengthSource)" : .*\n`)

func TestGolden(t *testing.T) {
	paths, err := filepath.Glob("testdata/golden/*.txt")
	if err != nil || len(paths) == 0 {
		t.Fatalf("no golden files: %v", err)
	}
	cwd, err := syscall.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range paths {
		name := strings.TrimSuffix(filepath.Base(path), ".txt")
		t.Run(name, func(t *testing.T) {
			g, err := readGolden(path)
			if err != nil {
				t.Fatal(err)
			}
			var stdout, stderr bytes.Buffer
			env := cli.Env{
				Stdout:   &stdout,
				Stderr:   &stderr,
				Now:      func() time.Time { return g.now },
				Location: g.location,
				Columns:  func() int { return g.columns },
			}
			code := cli.Run(g.args, env)
			gotOut := strings.ReplaceAll(stdout.String(), cwd, "{{CWD}}")
			gotErr := strings.ReplaceAll(stderr.String(), cwd, "{{CWD}}")

			if *update {
				g.sections["stdout"], g.sections["stderr"], g.exit = gotOut, gotErr, code
				if err := g.write(path); err != nil {
					t.Fatal(err)
				}
			}
			if code != g.exit {
				t.Errorf("exit code %d, want %d", code, g.exit)
			}
			if gotOut != g.sections["stdout"] {
				t.Errorf("stdout differs\n--- got\n%s--- want\n%s", gotOut, g.sections["stdout"])
			}
			if gotErr != g.sections["stderr"] {
				t.Errorf("stderr differs\n--- got\n%s--- want\n%s", gotErr, g.sections["stderr"])
			}
			if swift, ok := g.sections["swift-stdout"]; ok && strings.HasPrefix(swift, "{") {
				if v1 := addedInV1.ReplaceAllString(gotOut, ""); v1 != swift {
					t.Errorf("JSON isn't the Swift output plus the v1 fields\n--- got, without them\n%s--- Swift\n%s", v1, swift)
				}
			}
		})
	}
}

type golden struct {
	header   []string
	args     []string
	now      time.Time
	location *time.Location
	columns  int
	exit     int
	sections map[string]string
	order    []string
}

var sectionMarker = regexp.MustCompile(`^-- ([a-z-]+) --$`)

func readGolden(path string) (*golden, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	g := &golden{columns: 80, sections: map[string]string{}}
	lines := strings.SplitAfter(string(data), "\n")
	section := ""
	for _, line := range lines {
		if m := sectionMarker.FindStringSubmatch(strings.TrimSuffix(line, "\n")); m != nil {
			section = m[1]
			g.order = append(g.order, section)
			g.sections[section] = ""
			continue
		}
		if section != "" {
			g.sections[section] += line
			continue
		}
		if line == "" {
			continue
		}
		key, value, _ := strings.Cut(strings.TrimSuffix(line, "\n"), ": ")
		switch key {
		case "args":
			if g.args, err = shellWords(value); err != nil {
				return nil, err
			}
		case "now":
			if g.now, err = time.Parse(time.RFC3339Nano, value); err != nil {
				return nil, err
			}
		case "tz":
			if g.location, err = time.LoadLocation(value); err != nil {
				return nil, err
			}
		case "columns":
			if g.columns, err = strconv.Atoi(value); err != nil {
				return nil, err
			}
		case "exit":
			if g.exit, err = strconv.Atoi(value); err != nil {
				return nil, err
			}
			continue
		default:
			return nil, fmt.Errorf("unknown header line %q", line)
		}
		g.header = append(g.header, line)
	}
	return g, nil
}

func (g *golden) write(path string) error {
	var b strings.Builder
	for _, line := range g.header {
		b.WriteString(line)
	}
	fmt.Fprintf(&b, "exit: %d\n", g.exit)
	for _, section := range g.order {
		fmt.Fprintf(&b, "-- %s --\n%s", section, g.sections[section])
	}
	return os.WriteFile(path, []byte(b.String()), 0o644)
}

// shellWords splits the `args:` line, which is quoted the way bash's
// printf %q quotes: backslash escapes and '' for an empty argument.
func shellWords(line string) ([]string, error) {
	var words []string
	var word strings.Builder
	inWord, quoted := false, false
	for i := 0; i < len(line); i++ {
		c := line[i]
		switch {
		case quoted:
			if c == '\'' {
				quoted = false
			} else {
				word.WriteByte(c)
			}
		case c == '\'':
			quoted, inWord = true, true
		case c == '\\' && i+1 < len(line):
			i++
			word.WriteByte(line[i])
			inWord = true
		case c == ' ':
			if inWord {
				words = append(words, word.String())
				word.Reset()
				inWord = false
			}
		default:
			word.WriteByte(c)
			inWord = true
		}
	}
	if quoted {
		return nil, fmt.Errorf("unterminated quote in %q", line)
	}
	if inWord {
		words = append(words, word.String())
	}
	return words, nil
}
