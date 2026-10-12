// Package cli is the gatekeepr command line: argument parsing, help, and the
// status and history commands.
package cli

import (
	"fmt"
	"io"
	"os"
	"strconv"
	"time"

	"github.com/akramsaouri/gatekeepr/internal/core"
)

// Version is printed by `gatekeepr --version`. scripts/build-release and
// scripts/check-release read it from this line, so keep it a plain literal.
const Version = "0.3.0"

// Env is everything the command line touches outside its arguments, so tests
// can fake it.
type Env struct {
	Stdout, Stderr io.Writer
	Now            func() time.Time
	// Location is the time zone times are shown in.
	Location *time.Location
	// Columns is the width help is wrapped to.
	Columns func() int
}

// System is the real environment.
func System() Env {
	return Env{
		Stdout:   os.Stdout,
		Stderr:   os.Stderr,
		Now:      time.Now,
		Location: time.Local,
		Columns:  terminalColumns,
	}
}

// terminalColumns is $COLUMNS, else the width of the terminal on stdout, else 80.
func terminalColumns() int {
	if columns, err := strconv.Atoi(os.Getenv("COLUMNS")); err == nil {
		return columns
	}
	if columns := terminalWidth(os.Stdout); columns > 0 {
		return columns
	}
	return 80
}

// Exit codes beyond the ones a status maps to.
const (
	exitUnreadable = 3
	exitUsage      = 64
)

// Run runs gatekeepr with args (without the program name) and returns the exit code.
func Run(args []string, env Env) int {
	call := parseArguments(args)
	switch {
	case call.err != nil:
		fmt.Fprintln(env.Stderr, call.err.fullText())
		return exitUsage
	case call.helpStack != nil:
		fmt.Fprintln(env.Stdout, call.helpStack[len(call.helpStack)-1].page.render(env.Columns()))
		return 0
	case call.version:
		fmt.Fprintln(env.Stdout, Version)
		return 0
	case call.command == historyCommand:
		return runHistory(call, env)
	default:
		return runStatus(call, env)
	}
}

func runStatus(call invocation, env Env) int {
	status, err := core.New(call.logDir, env.Now).Status(call.warn)
	if err != nil {
		return fail(err, call.json, call.short, env)
	}
	switch {
	case call.json:
		fmt.Fprintln(env.Stdout, core.StatusReport(status, env.Location))
	case call.short:
		fmt.Fprintln(env.Stdout, core.ShortStatus(status))
	default:
		fmt.Fprintln(env.Stdout, statusText(status, call.logDir, env.Location))
	}
	return status.State.ExitCode()
}

func runHistory(call invocation, env Env) int {
	analysis, err := core.New(call.logDir, env.Now).Analyze()
	if err != nil {
		return fail(err, call.json, false, env)
	}
	if call.json {
		fmt.Fprintln(env.Stdout, core.HistoryReport(analysis, env.Location))
	} else {
		fmt.Fprintln(env.Stdout, historyText(analysis, call.logDir, env.Location))
	}
	return 0
}

// fail reports an error the way the chosen output format expects, and returns exit code 3.
func fail(err error, json, short bool, env Env) int {
	message := err.Error()
	fmt.Fprintf(env.Stderr, "gatekeepr: %s\n", message)
	switch {
	case json:
		fmt.Fprintln(env.Stdout, core.ErrorReport(message))
	case short:
		fmt.Fprintln(env.Stdout, core.ShortError)
	}
	return exitUnreadable
}
