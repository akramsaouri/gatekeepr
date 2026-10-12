package cli

import "strings"

// Help pages, laid out exactly as swift-argument-parser laid out the Swift
// version's: wrapped to the terminal width, with option descriptions in a
// column at 26.

const (
	helpIndent       = 2
	labelColumnWidth = 26
)

type helpRow struct {
	label    string
	abstract string
}

type helpSection struct {
	header string
	rows   []helpRow
}

type helpPage struct {
	// abstract includes the discussion, after a blank line.
	abstract string
	usage    string
	sections []helpSection
	// footer follows the sections, for commands with subcommands.
	footer string
}

func (p helpPage) render(width int) string {
	var sections []string
	for _, section := range p.sections {
		if len(section.rows) == 0 {
			continue
		}
		var b strings.Builder
		b.WriteString(section.header + ":\n")
		for _, row := range section.rows {
			b.WriteString(row.render(width))
		}
		sections = append(sections, b.String())
	}
	var b strings.Builder
	if p.abstract != "" {
		b.WriteString(wrap("OVERVIEW: "+p.abstract, width, 0) + "\n\n")
	}
	if p.usage != "" {
		b.WriteString("USAGE: " + p.usage + "\n\n")
	}
	b.WriteString(strings.Join(sections, "\n"))
	b.WriteString(p.footer)
	return b.String()
}

func (r helpRow) render(width int) string {
	padded := strings.Repeat(" ", helpIndent) + r.label
	abstract := ""
	if r.abstract != "" {
		wrapped := wrap(r.abstract, width, labelColumnWidth)
		if len([]rune(padded)) < labelColumnWidth {
			abstract = dropFirst(wrapped, len([]rune(padded)))
		} else {
			abstract = "\n" + wrapped
		}
	}
	return padded + abstract + "\n"
}

func dropFirst(s string, n int) string {
	runes := []rune(s)
	if n >= len(runes) {
		return ""
	}
	return string(runes[n:])
}

// wrap is swift-argument-parser's String.wrapped(to:wrappingIndent:): break
// at the last space that fits, or past a word longer than the line, keep
// existing line breaks, and indent every non-empty line.
func wrap(text string, columns, indent int) string {
	columns -= indent
	if columns <= 0 {
		return ""
	}
	s := []rune(text)
	var lines []string
	current := 0
	for {
		chunkEnd := min(current+columns, len(s))
		chunk := s[current:chunkEnd]
		if lastBreak := lastIndex(chunk, '\n'); lastBreak >= 0 {
			lines = append(lines, strings.Split(string(s[current:current+lastBreak]), "\n")...)
			current += lastBreak + 1
		} else if chunkEnd == len(s) {
			lines = append(lines, string(s[current:]))
			break
		} else if lastSpace := lastIndex(chunk, ' '); lastSpace >= 0 {
			lines = append(lines, string(s[current:current+lastSpace]))
			current += lastSpace + 1
		} else if nextSpace := indexFrom(s, current, ' '); nextSpace >= 0 {
			lines = append(lines, string(s[current:nextSpace]))
			current = nextSpace + 1
		} else {
			lines = append(lines, string(s[current:]))
			break
		}
	}
	prefix := strings.Repeat(" ", indent)
	for i, line := range lines {
		if line != "" {
			lines[i] = prefix + line
		}
	}
	return strings.Join(lines, "\n")
}

func lastIndex(s []rune, r rune) int {
	for i := len(s) - 1; i >= 0; i-- {
		if s[i] == r {
			return i
		}
	}
	return -1
}

// indexFrom is the first index of r at or after from.
func indexFrom(s []rune, from int, r rune) int {
	for i := from; i < len(s); i++ {
		if s[i] == r {
			return i
		}
	}
	return -1
}
