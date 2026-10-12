package core

import (
	"encoding/json"
	"math"
	"strings"
	"time"
)

// Every line must look like `[2026-10-10T23:24:41.741Z] Info : <message>`
// (UTC timestamps). A line that doesn't is an error rather than something to
// skip, and so is a session-related line with an unexpected shape: these are
// observed, undocumented formats, so gatekeepr fails loudly instead of guessing.

const (
	requestPrefix = "Got request from client <"
	replyPrefix   = "Sending reply to client <"
)

// ParseEvents turns driver log text into session events. file is the log
// file's name, for error messages.
func ParseEvents(text, file string) ([]Event, error) {
	var events []Event
	lines := strings.Split(text, "\n")
	for index, line := range lines {
		line = strings.TrimSuffix(line, "\r")
		if isBlank(line) {
			continue
		}
		number := index + 1

		envelope, ok := parseEnvelope(line)
		if !ok {
			// A last line with no newline yet may still be being written.
			if index == len(lines)-1 && strings.HasPrefix(line, "[") {
				continue
			}
			return nil, &Error{Kind: UnrecognizedLine, File: file, Line: number, Text: line}
		}
		unrecognized := func(reason string) error {
			return &Error{Kind: UnrecognizedEvent, File: file, Line: number, Text: line, Reason: reason}
		}
		event, ok, err := classify(envelope.message, unrecognized)
		if err != nil {
			return nil, err
		}
		if !ok {
			continue
		}
		date, ok := envelope.date()
		if !ok {
			return nil, unrecognized("the timestamp isn't a real date")
		}
		event.Date = date
		event.File = file
		event.Line = number
		events = append(events, event)
	}
	return events, nil
}

// classify returns the event a message stands for; ok is false for noise.
func classify(message string, unrecognized func(string) error) (event Event, ok bool, err error) {
	if strings.HasPrefix(message, requestPrefix) &&
		(strings.Contains(message, `"login"`) || strings.Contains(message, `"deploy"`)) {
		request, valid := payload(message, requestPrefix)
		if !valid {
			return Event{}, false, unrecognized("a login or deploy request isn't valid JSON")
		}
		method, _ := request["method"].(string)
		params, _ := request["params"].(map[string]any)
		inner, _ := params["message"].(map[string]any)
		innerMethod, _ := inner["method"].(string)
		if method == "deploy" {
			return Event{Kind: Deploy}, true, nil
		}
		if method == "send-to" && innerMethod == "login" {
			site, isString := params["site-id"].(string)
			if !isString {
				return Event{}, false, unrecognized("a login request has no site-id")
			}
			return Event{Kind: Login, Site: site}, true, nil
		}
		if method == "login" || innerMethod == "login" {
			return Event{}, false, unrecognized("a login request isn't wrapped in send-to as expected")
		}
		return Event{}, false, nil
	}

	if strings.Contains(message, "token-renewal-notification") {
		reply, valid := payload(message, replyPrefix)
		params, _ := reply["params"].(map[string]any)
		inner, _ := params["message"].(map[string]any)
		method, _ := inner["method"].(string)
		if !valid || params == nil || inner == nil || method != "token-renewal-notification" {
			return Event{}, false, unrecognized("a token-renewal-notification isn't the expected send-to reply")
		}
		innerParams, _ := inner["params"].(map[string]any)
		timeLeft, isNumber := innerParams["timeLeft"].(float64)
		if !isNumber || timeLeft < 0 {
			return Event{}, false, unrecognized("a token-renewal-notification has no usable timeLeft")
		}
		left := time.Duration(math.Round(timeLeft * float64(time.Second)))
		return Event{Kind: RenewalNotification, TimeLeft: left}, true, nil
	}

	if strings.Contains(message, "Closing *:") {
		reason, valid := closeReason(message)
		if !valid {
			return Event{}, false, unrecognized("a connection close doesn't look like `[SITE] [gateway] Closing *:PORT (reason)`")
		}
		// "Client closed control connection" is the client going away.
		// Everything else (Disconnected by gateway, Dead connection detected,
		// IP address change, timeouts) is the network, and a reconnect follows.
		if strings.HasPrefix(reason, "Client") {
			return Event{Kind: ClientClosed}, true, nil
		}
		return Event{}, false, nil
	}

	switch {
	case message == "Client closed control connection":
		return Event{Kind: ClientClosed}, true, nil
	case message == "Got control connection":
		return Event{Kind: ClientConnected}, true, nil
	case strings.HasPrefix(message, "Starting event loop"), strings.HasPrefix(message, "Stopping event loop"):
		return Event{Kind: DriverRestarted}, true, nil
	}
	return Event{}, false, nil
}

// payload is the JSON object in `<prefix>{...}>`.
func payload(message, prefix string) (map[string]any, bool) {
	if !strings.HasPrefix(message, prefix) || !strings.HasSuffix(message, ">") {
		return nil, false
	}
	var object map[string]any
	if err := json.Unmarshal([]byte(message[len(prefix):len(message)-1]), &object); err != nil || object == nil {
		return nil, false
	}
	return object, true
}

// closeReason turns `[AWS] [sdp-gw1-aws] Closing *:54679 (Disconnected by gateway)`
// into `Disconnected by gateway`.
func closeReason(message string) (string, bool) {
	rest := message
	for strings.HasPrefix(rest, "[") {
		end := strings.IndexByte(rest, ']')
		if end < 0 {
			return "", false
		}
		rest = rest[end+1:]
		if !strings.HasPrefix(rest, " ") {
			return "", false
		}
		rest = rest[1:]
	}
	if !strings.HasPrefix(rest, "Closing *:") {
		return "", false
	}
	rest = rest[len("Closing *:"):]
	port := 0
	for port < len(rest) && rest[port] >= '0' && rest[port] <= '9' {
		port++
	}
	if port == 0 {
		return "", false
	}
	rest = rest[port:]
	if !strings.HasPrefix(rest, " (") || !strings.HasSuffix(rest, ")") || len(rest) < 3 {
		return "", false
	}
	return rest[2 : len(rest)-1], true
}

// envelope is `[2026-10-10T23:24:41.741Z] Info : <message>`, split up.
type envelope struct {
	// timestamp is `2026-10-10T23:24:41.741Z`, shape already checked.
	timestamp string
	level     string
	message   string
}

const timestampShape = "dddd-dd-ddTdd:dd:dd.dddZ"

func parseEnvelope(line string) (envelope, bool) {
	if len(line) <= len(timestampShape)+2 || line[0] != '[' {
		return envelope{}, false
	}
	start, end := 1, 1+len(timestampShape)
	for i := 0; i < len(timestampShape); i++ {
		c, want := line[start+i], timestampShape[i]
		if want == 'd' && (c < '0' || c > '9') || want != 'd' && c != want {
			return envelope{}, false
		}
	}
	// "] " + level + " : "
	cursor := end
	if line[cursor] != ']' {
		return envelope{}, false
	}
	cursor++
	if cursor >= len(line) || line[cursor] != ' ' {
		return envelope{}, false
	}
	cursor++
	levelStart := cursor
	for cursor < len(line) && isASCIILetter(line[cursor]) {
		cursor++
	}
	levelEnd := cursor
	if levelStart == levelEnd {
		return envelope{}, false
	}
	for _, want := range []byte(" : ") {
		// The message may be empty, in which case the trailing space can be missing.
		if cursor == len(line) && want == ' ' {
			break
		}
		if cursor >= len(line) || line[cursor] != want {
			return envelope{}, false
		}
		cursor++
	}
	return envelope{timestamp: line[start:end], level: line[levelStart:levelEnd], message: line[cursor:]}, true
}

func isASCIILetter(c byte) bool { return c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' }

// date is the timestamp as a UTC time; ok is false for impossible dates like 2026-02-30.
func (e envelope) date() (time.Time, bool) {
	number := func(from, to int) int {
		n := 0
		for i := from; i < to; i++ {
			n = n*10 + int(e.timestamp[i]-'0')
		}
		return n
	}
	year, month, day := number(0, 4), number(5, 7), number(8, 10)
	hour, minute, second := number(11, 13), number(14, 16), number(17, 19)
	millisecond := number(20, 23)
	if month < 1 || month > 12 || day < 1 || day > daysIn(month, year) || hour >= 24 || minute >= 60 || second >= 61 {
		return time.Time{}, false
	}
	// time.Date carries a leap second (:60) into the next minute, as the Swift version did.
	return time.Date(year, time.Month(month), day, hour, minute, second, millisecond*int(time.Millisecond), time.UTC), true
}

func daysIn(month, year int) int {
	switch month {
	case 2:
		if year%4 == 0 && (year%100 != 0 || year%400 == 0) {
			return 29
		}
		return 28
	case 4, 6, 9, 11:
		return 30
	}
	return 31
}
