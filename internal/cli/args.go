package cli

import (
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/akramsaouri/gatekeepr/internal/core"
)

// This parses arguments the way swift-argument-parser parsed them for the
// Swift version, quirks included, so scripts and muscle memory keep working:
// the same option forms, the same precedence between errors, help and
// --version, and the same messages. CommandParser.swift and SplitArguments.swift
// in swift-argument-parser 1.7 are the reference.

// optionSpec is one --option of a command.
type optionSpec struct {
	long string
	// valueName is the <placeholder> of an option that takes a value; empty for a flag.
	valueName    string
	abstract     string
	defaultValue string
}

func (o optionSpec) isFlag() bool { return o.valueName == "" }

func (o optionSpec) synopsis() string {
	if o.isFlag() {
		return "--" + o.long
	}
	return "--" + o.long + " <" + o.valueName + ">"
}

type commandSpec struct {
	name    string
	options []optionSpec
	// subcommands and defaultSubcommand are set on the root only.
	subcommands       []*commandSpec
	defaultSubcommand *commandSpec
	// isHelp marks the `help` subcommand, which swift-argument-parser adds:
	// it has no help flags of its own and takes subcommand names.
	isHelp bool
	page   helpPage
}

var (
	logDirOption = optionSpec{long: "log-dir", valueName: "path", abstract: "Where Appgate writes driver.log.", defaultValue: core.AppgateLogDirectory}
	jsonOption   = optionSpec{long: "json", abstract: "Print JSON instead of text."}
	shortOption  = optionSpec{long: "short", abstract: "Print only the time left, like 6h08m, for statuslines."}
	warnOption   = optionSpec{long: "warn", valueName: "duration", abstract: "Exit with 1 when this much time or less is left, e.g. 30m, 2h, 1h30m.", defaultValue: "30m"}
)

var (
	statusCommand  = &commandSpec{name: "status", options: []optionSpec{logDirOption, jsonOption, shortOption, warnOption}}
	historyCommand = &commandSpec{name: "history", options: []optionSpec{logDirOption, jsonOption}}
	helpCommand    = &commandSpec{name: "help", isHelp: true}
	rootCommand    = &commandSpec{name: "gatekeepr", subcommands: []*commandSpec{statusCommand, historyCommand, helpCommand}, defaultSubcommand: statusCommand}
)

const (
	rootAbstract = "Shows when your Appgate SDP session expires."
	// rootDiscussion follows the abstract in `gatekeepr --help`.
	rootDiscussion = "Works it out from Appgate's driver logs, which any user can read. No root, " +
		"no network. Unofficial and not affiliated with Appgate.\n\n" +
		"Exit codes: 0 ok, 1 within the warn window, 2 expired or not signed in, " +
		"3 logs unreadable or in a format gatekeepr doesn't know."
	statusAbstract  = "Show the current session: sign-in time, expiry and time left."
	historyAbstract = "List past sessions with their measured lengths."
)

var (
	versionRow  = helpRow{"--version", "Show the version."}
	helpFlagRow = helpRow{"-h, --help", "Show help information."}
)

func init() {
	rootCommand.page = helpPage{
		abstract: rootAbstract + "\n\n" + rootDiscussion,
		usage:    "gatekeepr <subcommand>",
		sections: []helpSection{
			{"OPTIONS", []helpRow{versionRow, helpFlagRow}},
			{"SUBCOMMANDS", []helpRow{{"status (default)", statusAbstract}, {"history", historyAbstract}}},
		},
		footer: "\n  See 'gatekeepr help <subcommand>' for detailed help.",
	}
	for _, command := range []*commandSpec{statusCommand, historyCommand} {
		var rows []helpRow
		for _, option := range command.options {
			abstract := option.abstract
			if option.defaultValue != "" {
				abstract += " (default: " + option.defaultValue + ")"
			}
			rows = append(rows, helpRow{option.synopsis(), abstract})
		}
		command.page = helpPage{
			usage:    command.usage(),
			sections: []helpSection{{"OPTIONS", append(rows, versionRow, helpFlagRow)}},
		}
	}
	statusCommand.page.abstract = statusAbstract
	historyCommand.page.abstract = historyAbstract
	helpCommand.page = helpPage{
		abstract: "Show subcommand help information.",
		usage:    helpCommand.usage(),
		sections: []helpSection{
			{"ARGUMENTS", []helpRow{{"<subcommands>", ""}}},
			{"OPTIONS", []helpRow{versionRow}},
		},
	}
}

func (c *commandSpec) usage() string {
	switch {
	case c == rootCommand:
		return "gatekeepr <subcommand>"
	case c.isHelp:
		return "gatekeepr help [<subcommands> ...]"
	}
	parts := []string{"gatekeepr", c.name}
	for _, option := range c.options {
		parts = append(parts, "["+option.synopsis()+"]")
	}
	return strings.Join(parts, " ")
}

func (c *commandSpec) option(n name) (optionSpec, bool) {
	if n.kind != longName {
		return optionSpec{}, false
	}
	for _, option := range c.options {
		if option.long == n.text {
			return option, true
		}
	}
	return optionSpec{}, false
}

func (c *commandSpec) subcommand(text string) *commandSpec {
	for _, sub := range c.subcommands {
		if sub.name == text {
			return sub
		}
	}
	return nil
}

// Splitting arguments into elements, as SplitArguments.swift does.

type nameKind int

const (
	longName nameKind = iota
	shortName
	// singleDashName is `-name`, a long name with one dash. It's also read as a
	// pack of short flags, so `-hx` asks for help.
	singleDashName
)

type name struct {
	kind nameKind
	text string
}

func (n name) synopsis() string {
	if n.kind == longName {
		return "--" + n.text
	}
	return "-" + n.text
}

type elementKind int

const (
	valueElement elementKind = iota
	optionElement
	terminatorElement
)

type element struct {
	kind elementKind
	// input is the argument this came from; sub is the position in a pack of
	// short flags, or -1 for the whole argument.
	input int
	sub   int
	// text is a value element's text.
	text string
	// name, value and hasValue are an option element's `--name=value`.
	name     name
	value    string
	hasValue bool
}

type usageError struct {
	message string
	// help is the `Help:` line, if any.
	help  string
	stack []*commandSpec
}

func splitArguments(args []string) ([]element, *usageError) {
	var elements []element
	for position, arg := range args {
		dashes := 0
		for dashes < len(arg) && arg[dashes] == '-' {
			dashes++
		}
		if dashes == len(arg) {
			switch dashes {
			case 0, 1:
				elements = append(elements, element{kind: valueElement, input: position, sub: -1, text: arg})
				continue
			case 2:
				elements = append(elements, element{kind: terminatorElement, input: position, sub: -1})
				// Everything after the first `--` is a value.
				for rest, value := range args[position+1:] {
					elements = append(elements, element{kind: valueElement, input: position + 1 + rest, sub: -1, text: value})
				}
				return elements, nil
			}
			return nil, invalidOption(arg)
		}
		switch dashes {
		case 0:
			elements = append(elements, element{kind: valueElement, input: position, sub: -1, text: arg})
		case 1:
			remainder := arg[1:]
			if equals := strings.IndexByte(remainder, '='); equals >= 0 {
				if equals == 0 {
					return nil, invalidOption(singleDash(remainder).synopsis())
				}
				elements = append(elements, element{kind: optionElement, input: position, sub: -1,
					name: singleDash(remainder[:equals]), value: remainder[equals+1:], hasValue: true})
				continue
			}
			n := singleDash(remainder)
			elements = append(elements, element{kind: optionElement, input: position, sub: -1, name: n})
			if n.kind == singleDashName {
				sub := 0
				for _, r := range remainder {
					elements = append(elements, element{kind: optionElement, input: position, sub: sub, name: name{shortName, string(r)}})
					sub++
				}
			}
		case 2:
			base, value, _ := strings.Cut(arg, "=")
			elements = append(elements, element{kind: optionElement, input: position, sub: -1,
				name: name{longName, base[2:]}, value: value, hasValue: value != ""})
		default:
			return nil, invalidOption(arg)
		}
	}
	return elements, nil
}

// singleDash is `-c` as a short name, and anything longer as a single-dash long name.
func singleDash(text string) name {
	if utf8.RuneCountInString(text) == 1 {
		return name{shortName, text}
	}
	return name{singleDashName, text}
}

func invalidOption(text string) *usageError {
	return &usageError{message: "Invalid option: " + text, stack: []*commandSpec{rootCommand}}
}

// Parsing, as CommandParser.swift does.

// invocation is what the arguments ask for.
type invocation struct {
	// command is statusCommand or historyCommand, with its options below.
	command *commandSpec
	logDir  string
	json    bool
	short   bool
	warn    time.Duration

	// helpStack is set when the arguments ask for help: the command to show it for.
	helpStack []*commandSpec
	version   bool
	err       *usageError
}

func parseArguments(args []string) invocation {
	split, err := splitArguments(args)
	if err != nil {
		return invocation{err: err}
	}
	result := invocation{logDir: core.AppgateLogDirectory, warn: 30 * time.Minute}
	var helpSubcommands []string
	stack := []*commandSpec{rootCommand}
	for {
		current := stack[len(stack)-1]
		if current.isHelp {
			split, helpSubcommands, err = parseHelpCommand(split)
		} else {
			split, err = parseOptions(current, split, &result)
		}
		if err != nil {
			err.stack = stack
			return invocation{err: err}
		}
		if current == statusCommand && result.json && result.short {
			if builtIn := builtInFlags(split, stack, false); builtIn != nil {
				return *builtIn
			}
			return invocation{err: &usageError{message: "--json and --short can't be used together.", stack: stack}}
		}
		// The next subcommand, if the next argument names one.
		if len(split) > 0 && split[0].kind == valueElement {
			if next := current.subcommand(args[split[0].input]); next != nil {
				split = split[1:]
				stack = append(stack, next)
				continue
			}
		}
		// A lone --help or --version before falling back to the default command.
		if builtIn := builtInFlags(split, stack, true); builtIn != nil {
			return *builtIn
		}
		if current.defaultSubcommand != nil {
			stack = append(stack, current.defaultSubcommand)
			continue
		}
		break
	}
	if builtIn := builtInFlags(split, stack, false); builtIn != nil {
		return *builtIn
	}
	current := stack[len(stack)-1]
	var extra []string
	for _, e := range split {
		switch e.kind {
		case optionElement:
			return invocation{err: &usageError{message: unknownOptionMessage(current, e.name), stack: stack}}
		case valueElement:
			if e.sub < 0 {
				extra = append(extra, e.text)
			}
		}
	}
	switch len(extra) {
	case 0:
	case 1:
		return invocation{err: &usageError{message: fmt.Sprintf("Unexpected argument '%s'", extra[0]), stack: stack}}
	default:
		return invocation{err: &usageError{message: fmt.Sprintf("%d unexpected arguments: '%s'", len(extra), strings.Join(extra, "', '")), stack: stack}}
	}
	if current.isHelp {
		return invocation{helpStack: helpStackFor(helpSubcommands)}
	}
	result.command = current
	return result
}

// parseOptions takes the command's options out of split, leaving everything
// it doesn't know for later errors. Bad or missing values fail at once.
func parseOptions(command *commandSpec, split []element, result *invocation) ([]element, *usageError) {
	used := make([]bool, len(split))
	for i, e := range split {
		if used[i] || e.kind != optionElement {
			continue
		}
		option, ok := command.option(e.name)
		if !ok {
			continue
		}
		used[i] = true
		if option.isFlag() {
			if e.hasValue {
				return nil, &usageError{message: fmt.Sprintf("The option '%s' does not take any value, but '%s' was specified.", e.name.synopsis(), e.value)}
			}
			switch option.long {
			case "json":
				result.json = true
			case "short":
				result.short = true
			}
			continue
		}
		value, found := e.value, e.hasValue
		if !found {
			// The next whole argument, if it's a value.
			for j := i + 1; j < len(split); j++ {
				if split[j].input == e.input || used[j] {
					continue
				}
				if split[j].sub < 0 && split[j].kind == valueElement {
					value, found = split[j].text, true
					used[j] = true
				}
				break
			}
		}
		helpLine := e.name.synopsis() + " <" + option.valueName + ">  " + option.abstract
		if !found {
			return nil, &usageError{message: fmt.Sprintf("Missing value for '%s <%s>'", e.name.synopsis(), option.valueName), help: helpLine}
		}
		switch option.long {
		case "log-dir":
			result.logDir = value
		case "warn":
			warn, ok := core.ParseDuration(value)
			if !ok {
				return nil, &usageError{message: fmt.Sprintf("The value '%s' is invalid for '%s <%s>'", value, e.name.synopsis(), option.valueName), help: helpLine}
			}
			result.warn = warn
		}
	}
	return removeUsed(split, used), nil
}

// parseHelpCommand takes `help`'s own (hidden) help flags and the subcommand
// names out of split.
func parseHelpCommand(split []element) ([]element, []string, *usageError) {
	used := make([]bool, len(split))
	var names []string
	for i, e := range split {
		if used[i] {
			continue
		}
		switch e.kind {
		case optionElement:
			if e.name == (name{shortName, "h"}) || e.name == (name{longName, "help"}) || e.name == (name{singleDashName, "help"}) {
				if e.hasValue {
					return nil, nil, &usageError{message: fmt.Sprintf("The option '%s' does not take any value, but '%s' was specified.", e.name.synopsis(), e.value)}
				}
				markUsed(split, used, i)
			}
		case valueElement:
			names = append(names, e.text)
			used[i] = true
		}
	}
	return removeUsed(split, used), names, nil
}

// markUsed marks an element used. A whole argument takes its pack of short
// flags with it; a flag from a pack takes the whole argument, but not the
// rest of the pack.
func markUsed(split []element, used []bool, i int) {
	used[i] = true
	for j, e := range split {
		if e.input != split[i].input {
			continue
		}
		if split[i].sub < 0 || e.sub < 0 {
			used[j] = true
		}
	}
}

func removeUsed(split []element, used []bool) []element {
	var rest []element
	for i, e := range split {
		if !used[i] {
			rest = append(rest, e)
		}
	}
	return rest
}

// builtInFlags finds --help (or -h, also inside a pack like -hx) and
// --version. With solo, they only count when they're all that's left, and
// come from a single argument.
func builtInFlags(split []element, stack []*commandSpec, solo bool) *invocation {
	if solo {
		if len(split) == 0 {
			return nil
		}
		for _, e := range split {
			if e.input != split[0].input {
				return nil
			}
		}
	}
	// The help command has no help flags of its own.
	if !stack[len(stack)-1].isHelp && (contains(split, name{shortName, "h"}) || contains(split, name{longName, "help"}) ||
		contains(split, name{longName, "help-hidden"})) {
		return &invocation{helpStack: stack}
	}
	if contains(split, name{longName, "version"}) {
		return &invocation{version: true}
	}
	return nil
}

func contains(split []element, n name) bool {
	for _, e := range split {
		if e.kind == optionElement && e.name == n {
			return true
		}
	}
	return false
}

// helpStackFor follows `help status ...` down the command tree as far as the
// names match.
func helpStackFor(names []string) []*commandSpec {
	stack := []*commandSpec{rootCommand}
	for _, n := range names {
		next := stack[len(stack)-1].subcommand(n)
		if next == nil {
			break
		}
		stack = append(stack, next)
	}
	return stack
}

func unknownOptionMessage(command *commandSpec, n name) string {
	if n.kind == shortName {
		return fmt.Sprintf("Unknown option '%s'", n.synopsis())
	}
	// Suggest the closest of the command's own options, if it's close enough.
	const similarityFloor = 4
	best, bestDistance := "", similarityFloor
	for _, option := range command.options {
		candidate := "--" + option.long
		if distance := editDistance(candidate, n.synopsis()); distance < bestDistance {
			best, bestDistance = candidate, distance
		}
	}
	if best != "" {
		return fmt.Sprintf("Unknown option '%s'. Did you mean '%s'?", n.synopsis(), best)
	}
	return fmt.Sprintf("Unknown option '%s'", n.synopsis())
}

// editDistance is the Levenshtein distance between two strings, by character.
func editDistance(a, b string) int {
	s, t := []rune(a), []rune(b)
	if len(s) == 0 || len(t) == 0 {
		return max(len(s), len(t))
	}
	previous := make([]int, len(t)+1)
	for j := range previous {
		previous[j] = j
	}
	for i := 1; i <= len(s); i++ {
		row := make([]int, len(t)+1)
		row[0] = i
		for j := 1; j <= len(t); j++ {
			cost := 1
			if s[i-1] == t[j-1] {
				cost = 0
			}
			row[j] = min(previous[j]+1, row[j-1]+1, previous[j-1]+cost)
		}
		previous = row
	}
	return previous[len(t)]
}

// fullText is the message swift-argument-parser printed for a usage error.
func (e *usageError) fullText() string {
	var b strings.Builder
	b.WriteString("Error: " + e.message + "\n")
	if e.help != "" {
		b.WriteString("Help:  " + e.help + "\n")
	}
	command := e.stack[len(e.stack)-1]
	b.WriteString("Usage: " + command.usage())
	if !command.isHelp {
		names := make([]string, len(e.stack))
		for i, c := range e.stack {
			names[i] = c.name
		}
		b.WriteString(fmt.Sprintf("\n  See '%s --help' for more information.", strings.Join(names, " ")))
	}
	return b.String()
}
