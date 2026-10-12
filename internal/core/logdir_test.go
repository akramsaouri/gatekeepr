package core

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestFindsDriverLogsOldestFirstAndIgnoresTheRest(t *testing.T) {
	files := map[string]string{}
	for _, name := range []string{"driver.log", "driver-2026-10-09.log.gz", "driver-2026-10-08.log", "driver.status",
		"notes.txt", "driver-latest.log.gz", "driver-2026-10-9.log.gz", "driver-2026-10-08.log.log"} {
		files[name] = ""
	}
	dir := writeFiles(t, files)
	found, err := LogDirectory{Path: dir}.Files()
	if err != nil {
		t.Fatal(err)
	}
	var names, dates []string
	for _, file := range found {
		names = append(names, file.Name())
		dates = append(dates, file.RotationDate)
	}
	if !reflect.DeepEqual(names, []string{"driver-2026-10-08.log", "driver-2026-10-09.log.gz", "driver.log"}) {
		t.Errorf("names %v", names)
	}
	if !reflect.DeepEqual(dates, []string{"2026-10-08", "2026-10-09", ""}) {
		t.Errorf("dates %v", dates)
	}
}

func TestDirectoryWithoutDriverLogs(t *testing.T) {
	dir := writeFiles(t, map[string]string{"driver.status": "{}"})
	_, err := LogDirectory{Path: dir}.Files()
	var dirErr *Error
	if !errors.As(err, &dirErr) || dirErr.Kind != NoLogFiles || dirErr.Path != dir {
		t.Errorf("got %#v", err)
	}
}

func TestDirectoryErrorsReadLikeTheSwiftVersion(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "file")
	if err := os.WriteFile(file, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	for path, want := range map[string]string{
		filepath.Join(dir, "does", "not", "exist"): "can't read the log directory " + dir + "/does/not/exist: The folder “exist” doesn’t exist.",
		file: "can't read the log directory " + file + ": Not a directory",
	} {
		_, err := LogDirectory{Path: path}.Files()
		if err == nil || err.Error() != want {
			t.Errorf("got %v\nwant %s", err, want)
		}
	}
}

func TestUnreadableDirectory(t *testing.T) {
	if os.Getuid() == 0 {
		t.Skip("root can read anything")
	}
	dir := filepath.Join(t.TempDir(), "locked")
	if err := os.Mkdir(dir, 0); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(dir, 0o755)
	_, err := LogDirectory{Path: dir}.Files()
	if err == nil || !strings.HasSuffix(err.Error(), ": Permission denied") {
		t.Errorf("got %v", err)
	}
}

func TestDisplayPath(t *testing.T) {
	wd := workingDirectory()
	for path, want := range map[string]string{
		"/var/log/appgate/": "/var/log/appgate",
		"//tmp/../tmp":      "//tmp/../tmp",
		"/":                 "/",
		"logs":              wd + "/logs",
		"./logs/../logs/":   wd + "/logs",
		"-":                 wd + "/-",
	} {
		if got := (LogDirectory{Path: path}).displayPath(); got != want {
			t.Errorf("%q: got %q, want %q", path, got, want)
		}
	}
}

func TestUnreadableFiles(t *testing.T) {
	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, "driver.log"), 0o755); err != nil {
		t.Fatal(err)
	}
	_, err := New(dir, time.Now).Analyze()
	if err == nil || err.Error() != "can't read driver.log: Is a directory" {
		t.Errorf("got %v", err)
	}

	dangling := t.TempDir()
	if err := os.Symlink(filepath.Join(dangling, "nowhere"), filepath.Join(dangling, "driver.log")); err != nil {
		t.Fatal(err)
	}
	_, err = New(dangling, time.Now).Analyze()
	if err == nil || err.Error() != "can't read driver.log: No such file or directory" {
		t.Errorf("got %v", err)
	}
}

func gunzipFixture(t *testing.T, path string) string {
	t.Helper()
	data, err := gunzip(readFixture(t, path))
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func TestGzip(t *testing.T) {
	text := gunzipFixture(t, "rotation/driver-2026-10-07.log.gz")
	if !strings.HasPrefix(text, "[2026-10-07T") || len(strings.Split(strings.TrimSuffix(text, "\n"), "\n")) != 40 {
		t.Errorf("unexpected text: %d lines", len(strings.Split(text, "\n")))
	}
}

func TestGzipWithSeveralMembers(t *testing.T) {
	// `cat a.gz b.gz > ab.gz` is a valid gzip file.
	joined := append(readFixture(t, "rotation/driver-2026-10-06.log.gz"), readFixture(t, "rotation/driver-2026-10-07.log.gz")...)
	want := gunzipFixture(t, "rotation/driver-2026-10-06.log.gz") + gunzipFixture(t, "rotation/driver-2026-10-07.log.gz")
	got, err := gunzip(joined)
	if err != nil || string(got) != want {
		t.Errorf("error %v, %d bytes, want %d", err, len(got), len(want))
	}
}

func TestGzipWithZeroPadding(t *testing.T) {
	padded := append(readFixture(t, "rotation/driver-2026-10-07.log.gz"), make([]byte, 512)...)
	got, err := gunzip(padded)
	if err != nil || string(got) != gunzipFixture(t, "rotation/driver-2026-10-07.log.gz") {
		t.Errorf("error %v", err)
	}
}

func TestEmptyGzipIsAnEmptyLog(t *testing.T) {
	if got, err := gunzip(nil); err != nil || len(got) != 0 {
		t.Errorf("got %q, %v", got, err)
	}
}

func TestTruncatedGzipFails(t *testing.T) {
	data := readFixture(t, "rotation/driver-2026-10-07.log.gz")
	for _, cut := range []int{len(data) / 2, 5, len(data) - 1} {
		if _, err := gunzip(data[:cut]); err == nil || err.Error() != "gzip data is truncated" {
			t.Errorf("cut at %d: %v", cut, err)
		}
	}
}

func TestCorruptGzipFails(t *testing.T) {
	data := bytes.Clone(readFixture(t, "rotation/driver-2026-10-07.log.gz"))
	middle := len(data) / 2
	data[middle] ^= 0xFF
	data[middle+1] ^= 0xFF
	if _, err := gunzip(data); err == nil || !strings.HasPrefix(err.Error(), "gzip data is corrupt (") {
		t.Errorf("got %v", err)
	}
}

func TestNotGzipFails(t *testing.T) {
	_, err := gunzip([]byte("[2026-10-10T23:24:41.741Z] Info : hello\n"))
	if err == nil || err.Error() != "gzip data is corrupt (incorrect header check)" {
		t.Errorf("got %v", err)
	}
}

func TestUnreadableArchiveIsReportedAsSuch(t *testing.T) {
	dir := writeFiles(t, map[string]string{"driver-2026-10-09.log.gz": "not gzip at all", "driver.log": ""})
	_, err := New(dir, time.Now).Analyze()
	want := "can't read driver-2026-10-09.log.gz: gzip data is corrupt (incorrect header check)"
	if err == nil || err.Error() != want {
		t.Errorf("got %v", err)
	}
}
