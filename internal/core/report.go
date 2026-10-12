package core

import (
	"sort"
	"strconv"
	"strings"
	"time"
)

// SchemaVersion is the version of the `--json` output, documented in
// docs/JSON.md. Any change to the schema bumps it, additions included.
const SchemaVersion = 1

// StatusReport is `gatekeepr --json`.
func StatusReport(status Status, loc *time.Location) string {
	report := jsonObject{
		{"schemaVersion", SchemaVersion},
		{"state", string(status.State)},
		{"exitCode", status.State.ExitCode()},
		{"now", isoDate(status.Now, loc)},
		{"warnThresholdSeconds", int64(status.WarnThreshold / time.Second)},
		{"sessionLengthSeconds", roundSeconds(status.SessionLength.Duration)},
		{"sessionLengthLearnedFrom", status.SessionLength.LearnedFrom},
		{"sessionLengthSource", sessionLengthSource(status.SessionLength)},
	}
	if session := status.Session; session != nil {
		report = append(report,
			jsonField{"sessionStart", isoDate(session.Start, loc)},
			jsonField{"sessionStartKind", string(session.StartKind)})
		// Set once the session has ended (signed out, or the client closed it on expiry).
		if !session.IsOpen() {
			report = append(report, jsonField{"sessionEnd", isoDate(session.End, loc)})
		}
	}
	if expiry := status.Expiry; expiry != nil {
		left, _ := status.TimeLeft()
		report = append(report,
			jsonField{"expiresAt", isoDate(expiry.Date, loc)},
			jsonField{"expirySource", string(expiry.Source)},
			// Negative once expired.
			jsonField{"secondsLeft", floorSeconds(left)},
			// Rounded down; `0m` once expired.
			jsonField{"timeLeft", FormatDuration(left, RoundDown)})
	}
	return report.encode()
}

// HistoryReport is `gatekeepr history --json`.
func HistoryReport(analysis Analysis, loc *time.Location) string {
	sessions := make([]any, 0, len(analysis.Sessions))
	for _, session := range analysis.Sessions {
		expiry := analysis.Expiry(session)
		entry := jsonObject{
			{"start", isoDate(session.Start, loc)},
			{"startKind", string(session.StartKind)},
			{"outcome", string(analysis.Outcome(session))},
			{"expiresAt", isoDate(expiry.Date, loc)},
			{"expirySource", string(expiry.Source)},
			{"reconnects", session.Reconnects},
		}
		if !session.IsOpen() {
			entry = append(entry,
				jsonField{"end", isoDate(session.End, loc)},
				jsonField{"endKind", string(session.EndKind)})
		}
		// Start to first renewal notice plus its timeLeft; absent if none was seen.
		if length, ok := session.MeasuredLength(); ok {
			entry = append(entry, jsonField{"measuredLengthSeconds", roundSeconds(length)})
		}
		sessions = append(sessions, entry)
	}
	return jsonObject{
		{"schemaVersion", SchemaVersion},
		{"now", isoDate(analysis.Now, loc)},
		{"sessionLengthSeconds", roundSeconds(analysis.SessionLength.Duration)},
		{"sessionLengthLearnedFrom", analysis.SessionLength.LearnedFrom},
		{"sessionLengthSource", sessionLengthSource(analysis.SessionLength)},
		// Oldest first.
		{"sessions", sessions},
	}.encode()
}

// ErrorReport is the `--json` output when the logs can't be read or parsed.
func ErrorReport(message string) string {
	return jsonObject{
		{"schemaVersion", SchemaVersion},
		{"state", "error"},
		{"exitCode", 3},
		{"error", message},
	}.encode()
}

// sessionLengthSource says how sessionLengthSeconds was worked out: the
// median of sessionLengthLearnedFrom measured sessions, or the 24h default.
func sessionLengthSource(length SessionLength) string {
	if length.IsFallback() {
		return "default"
	}
	return "median"
}

// isoDate is ISO 8601 with the offset of loc, to the second (truncated):
// `2026-10-12T01:24:40+02:00`, or `...Z` at UTC.
func isoDate(t time.Time, loc *time.Location) string {
	return t.In(loc).Format(time.RFC3339)
}

func floorSeconds(d time.Duration) int64 {
	seconds := int64(d / time.Second)
	if d%time.Second < 0 {
		seconds--
	}
	return seconds
}

// roundSeconds rounds half away from zero.
func roundSeconds(d time.Duration) int64 {
	return int64(d.Round(time.Second) / time.Second)
}

// jsonObject is a JSON object whose keys are written sorted, laid out the way
// the Swift version's Foundation encoders did it: two-space indent, `"key" :
// value`, and an empty array as `[` and `]` around a blank line. Values are
// strings, ints, int64s, nested objects or []any of those.
type jsonObject []jsonField

type jsonField struct {
	key   string
	value any
}

func (o jsonObject) encode() string {
	var b strings.Builder
	writeJSON(&b, o, "")
	return b.String()
}

func writeJSON(b *strings.Builder, value any, indent string) {
	inner := indent + "  "
	switch v := value.(type) {
	case jsonObject:
		fields := append(jsonObject(nil), v...)
		sort.Slice(fields, func(i, j int) bool { return fields[i].key < fields[j].key })
		b.WriteString("{\n")
		for i, field := range fields {
			b.WriteString(inner)
			writeJSONString(b, field.key)
			b.WriteString(" : ")
			writeJSON(b, field.value, inner)
			if i < len(fields)-1 {
				b.WriteString(",")
			}
			b.WriteString("\n")
		}
		b.WriteString(indent + "}")
	case []any:
		b.WriteString("[\n")
		if len(v) == 0 {
			b.WriteString("\n")
		}
		for i, element := range v {
			b.WriteString(inner)
			writeJSON(b, element, inner)
			if i < len(v)-1 {
				b.WriteString(",")
			}
			b.WriteString("\n")
		}
		b.WriteString(indent + "]")
	case string:
		writeJSONString(b, v)
	case int:
		b.WriteString(strconv.Itoa(v))
	case int64:
		b.WriteString(strconv.FormatInt(v, 10))
	default:
		panic("unsupported JSON value")
	}
}

// writeJSONString escapes like NSJSONSerialization with
// .withoutEscapingSlashes: quote, backslash and control characters only, with
// the short forms where JSON has them. Everything else is written as is.
func writeJSONString(b *strings.Builder, s string) {
	const hex = "0123456789abcdef"
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch c {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\b':
			b.WriteString(`\b`)
		case '\f':
			b.WriteString(`\f`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			if c < 0x20 {
				b.WriteString(`\u00`)
				b.WriteByte(hex[c>>4])
				b.WriteByte(hex[c&0xF])
			} else {
				b.WriteByte(c)
			}
		}
	}
	b.WriteByte('"')
}
