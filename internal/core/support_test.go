package core

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// utc parses `2026-10-09T12:00:00Z` or `2026-10-09T07:55:35.444Z`.
func utc(t testing.TB, text string) time.Time {
	t.Helper()
	date, err := time.Parse(time.RFC3339Nano, text)
	if err != nil {
		t.Fatalf("bad test date %s: %v", text, err)
	}
	return date
}

func assertDate(t testing.TB, actual, expected time.Time) {
	t.Helper()
	if diff := actual.Sub(expected); diff > time.Millisecond || diff < -time.Millisecond {
		t.Errorf("date is %s, want %s", actual.Format(time.RFC3339Nano), expected.Format(time.RFC3339Nano))
	}
}

func assertSeconds(t testing.TB, actual time.Duration, expected float64) {
	t.Helper()
	if diff := actual.Seconds() - expected; diff > 0.001 || diff < -0.001 {
		t.Errorf("duration is %.3fs, want %.3fs", actual.Seconds(), expected)
	}
}

// fixture is a log directory under testdata/fixtures: a sanitized, trimmed
// excerpt of a real /var/log/appgate (see testdata/fixtures/README.md).
func fixture(name string) string {
	return filepath.Join("..", "..", "testdata", "fixtures", name)
}

// analyzeFixture reads a fixture as it would have looked at now: later lines are ignored.
func analyzeFixture(t testing.TB, name, now string) Analysis {
	t.Helper()
	date := utc(t, now)
	analysis, err := New(fixture(name), func() time.Time { return date }).Analyze()
	if err != nil {
		t.Fatal(err)
	}
	return analysis
}

func statusOf(t testing.TB, name, now string, warn time.Duration) Status {
	t.Helper()
	return analyzeFixture(t, name, now).Status(warn)
}

const defaultWarn = 30 * time.Minute

// writeFiles makes a scratch log directory with the given files.
func writeFiles(t testing.TB, files map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	for name, text := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func readFixture(t testing.TB, path string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "testdata", "fixtures", path))
	if err != nil {
		t.Fatal(err)
	}
	return data
}
