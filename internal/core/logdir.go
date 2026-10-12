package core

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
)

// AppgateLogDirectory is where Appgate writes its driver logs on macOS.
const AppgateLogDirectory = "/var/log/appgate"

// LogFile is one Appgate driver log: the live driver.log or a rotated
// driver-YYYY-MM-DD.log.gz (or uncompressed .log).
type LogFile struct {
	Path string
	// RotationDate is the YYYY-MM-DD in a rotated file's name; empty for the
	// live driver.log.
	RotationDate string
}

func (f LogFile) Name() string       { return filepath.Base(f.Path) }
func (f LogFile) IsCompressed() bool { return filepath.Ext(f.Path) == ".gz" }

// logFile recognises driver log names; ok is false for anything else in the directory.
func logFile(dir, name string) (LogFile, bool) {
	path := filepath.Join(dir, name)
	if name == "driver.log" {
		return LogFile{Path: path}, true
	}
	rest, found := strings.CutPrefix(name, "driver-")
	if !found {
		return LogFile{}, false
	}
	var date string
	if d, ok := strings.CutSuffix(rest, ".log.gz"); ok {
		date = d
	} else if d, ok := strings.CutSuffix(rest, ".log"); ok {
		date = d
	} else {
		return LogFile{}, false
	}
	if len(date) != len("9999-99-99") {
		return LogFile{}, false
	}
	for i := 0; i < len(date); i++ {
		c := date[i]
		if i == 4 || i == 7 {
			if c != '-' {
				return LogFile{}, false
			}
		} else if c < '0' || c > '9' {
			return LogFile{}, false
		}
	}
	return LogFile{Path: path, RotationDate: date}, true
}

// LogDirectory is the directory Appgate writes its driver logs to.
type LogDirectory struct {
	// Path is the directory as the user gave it.
	Path string
}

// displayPath is the directory as error messages show it: relative paths are
// made absolute against the working directory and cleaned, absolute paths are
// left as given apart from trailing slashes. That's what the Swift version's
// URL(fileURLWithPath:).path printed.
func (d LogDirectory) displayPath() string {
	if filepath.IsAbs(d.Path) {
		trimmed := strings.TrimRight(d.Path, "/")
		if trimmed == "" {
			return "/"
		}
		return trimmed
	}
	return filepath.Join(workingDirectory(), d.Path)
}

// workingDirectory is the real path of the current directory (symlinks
// resolved, as getcwd(3) reports it), not $PWD.
func workingDirectory() string {
	if wd, err := syscall.Getwd(); err == nil {
		return wd
	}
	wd, _ := os.Getwd()
	return wd
}

// Files lists the driver logs, oldest first: rotated files by date, then the
// live driver.log.
func (d LogDirectory) Files() ([]LogFile, error) {
	entries, err := d.entries()
	if err != nil {
		return nil, err
	}
	var files []LogFile
	for _, entry := range entries {
		if file, ok := logFile(d.Path, entry.Name()); ok {
			files = append(files, file)
		}
	}
	sort.Slice(files, func(i, j int) bool {
		// driver.log has no rotation date and is always the newest.
		left, right := files[i].RotationDate, files[j].RotationDate
		if left == "" {
			left = "9999-99-99"
		}
		if right == "" {
			right = "9999-99-99"
		}
		if left == right {
			return files[i].Name() < files[j].Name()
		}
		return left < right
	})
	if len(files) == 0 {
		return nil, &Error{Kind: NoLogFiles, Path: d.displayPath()}
	}
	return files, nil
}

// Text is a log file's text, decompressed if needed.
func (d LogDirectory) Text(file LogFile) (string, error) {
	data, err := os.ReadFile(file.Path)
	if err != nil {
		return "", &Error{Kind: LogFileUnreadable, File: file.Name(), Reason: errnoText(err)}
	}
	if file.IsCompressed() {
		data, err = gunzip(data)
		if err != nil {
			return "", &Error{Kind: LogFileUnreadable, File: file.Name(), Reason: err.Error()}
		}
	}
	return repairUTF8(data), nil
}

// entries lists the directory, failing with the wording macOS Foundation used
// for the Swift version: its own sentence when the path can't be looked up
// at all (missing, a loop, a parent that isn't a directory or can't be
// searched), and the strerror(3) text otherwise. Checking first also means a
// FIFO or device is never opened, which could block.
func (d LogDirectory) entries() ([]fs.DirEntry, error) {
	fail := func(reason string) error {
		return &Error{Kind: LogDirectoryUnreadable, Path: d.displayPath(), Reason: reason}
	}
	info, err := os.Stat(d.Path)
	if err != nil {
		return nil, fail("The folder “" + filepath.Base(d.displayPath()) + "” doesn’t exist.")
	}
	if !info.IsDir() {
		return nil, fail(errnoText(syscall.ENOTDIR))
	}
	entries, err := os.ReadDir(d.Path)
	if err != nil {
		return nil, fail(errnoText(err))
	}
	return entries, nil
}

// errnoText is strerror(3) for the error's errno. Go's errno strings are
// macOS's strerror text with the first letter lowercased.
func errnoText(err error) string {
	var errno syscall.Errno
	if errors.As(err, &errno) {
		text := errno.Error()
		if text != "" {
			return strings.ToUpper(text[:1]) + text[1:]
		}
	}
	var pathErr *fs.PathError
	if errors.As(err, &pathErr) {
		return pathErr.Err.Error()
	}
	return err.Error()
}
