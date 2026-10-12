package core

import (
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"
)

// Sanitized lines in the shape Appgate client 6.5.3 writes them.
const (
	loginLine        = `[2026-10-10T23:24:41.741Z] Info : Got request from client <{"jsonrpc":"2.0","method":"send-to","params":{"id":"staticid","site-id":"AWS","message":{"jsonrpc":"2.0","id":2,"method":"login","params":{"claimsToken":"*","entitlementToken":"*","untrustedClaimsToken":"*","version":4}}}}>`
	updateTokensLine = `[2026-10-11T00:20:41.900Z] Info : Got request from client <{"jsonrpc":"2.0","method":"send-to","params":{"id":"staticid","site-id":"GCP","message":{"jsonrpc":"2.0","id":3,"method":"update-tokens","params":{"claimsToken":"*","entitlementToken":"*","untrustedClaimsToken":"*","version":4}}}}>`
	deployLine       = `[2026-10-10T23:24:41.129Z] Info : Got request from client <{"jsonrpc":"2.0","id":3,"method":"deploy","params":{"clientp12":"*","cacert":"*","sites":[],"id":"staticid"}}>`
	renewalLine      = `[2026-10-11T23:19:40.100Z] Info : Sending reply to client <{ "jsonrpc": "2.0", "method": "send-to", "params": { "id": "staticid", "site-id": "GCP", "message": {"method":"token-renewal-notification","params":{"id":"00000000-0000-4000-8000-000000000001","timeLeft":300},"jsonrpc":"2.0"} }}>`
	revocationLine   = `[2026-09-29T07:02:21.915Z] Info : Sending reply to client <{ "jsonrpc": "2.0", "method": "send-to", "params": { "id": "staticid", "site-id": "AWS", "message": {"method":"token-revocation","params":{"id":"00000000-0000-4000-8000-000000000003","timeLeft":300},"jsonrpc":"2.0"} }}>`
	statusLine       = `[2026-10-10T23:24:30.939Z] Info : Sending reply to client <{ "jsonrpc": "2.0", "method": "status", "params": { "id": "staticid", "ip4": "198.18.0.1", "sites": { "AWS": {"gw-id": "sdp-gw2-aws", "status": "down", "error": "Disconnected by gateway", "code": 108}} }}>`
)

type kind struct {
	kind     EventKind
	site     string
	timeLeft time.Duration
}

func kinds(t *testing.T, lines ...string) []kind {
	t.Helper()
	events, err := ParseEvents(strings.Join(lines, "\n")+"\n", "driver.log")
	if err != nil {
		t.Fatal(err)
	}
	return eventKinds(events)
}

func eventKinds(events []Event) []kind {
	result := []kind{}
	for _, e := range events {
		result = append(result, kind{e.Kind, e.Site, e.TimeLeft})
	}
	return result
}

func TestTimestampsAreUTC(t *testing.T) {
	events, err := ParseEvents(loginLine+"\n", "driver.log")
	if err != nil || len(events) != 1 {
		t.Fatalf("events %v, error %v", events, err)
	}
	assertDate(t, events[0].Date, utc(t, "2026-10-10T23:24:41.741Z"))
	if events[0].File != "driver.log" || events[0].Line != 1 {
		t.Errorf("location %s:%d", events[0].File, events[0].Line)
	}
}

func TestSessionEvents(t *testing.T) {
	got := kinds(t,
		"[2026-10-10T23:24:34.000Z] Info : Client closed control connection",
		"[2026-10-10T23:24:34.009Z] Info : [AWS] [] Closing *:0 (Client closed control connection)",
		"[2026-10-10T23:24:34.025Z] Info : [GCP] [] Closing *:51997 (Client closed control connection)",
		"[2026-10-10T23:24:41.117Z] Info : Got control connection",
		deployLine,
		loginLine,
		renewalLine,
		"[2026-10-07T06:12:29.811Z] Info : Starting event loop",
		"[2026-09-28T07:08:40.000Z] Info : Stopping event loop (killed by: 1|/sbin/launchd signo/code: 15/0)",
	)
	want := []kind{
		{kind: ClientClosed}, {kind: ClientClosed}, {kind: ClientClosed}, {kind: ClientConnected}, {kind: Deploy},
		{kind: Login, site: "AWS"}, {kind: RenewalNotification, timeLeft: 300 * time.Second},
		{kind: DriverRestarted}, {kind: DriverRestarted},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %v\nwant %v", got, want)
	}
}

func TestNoiseIsIgnored(t *testing.T) {
	got := kinds(t,
		updateTokensLine,
		revocationLine,
		statusLine,
		"[2026-10-10T23:24:43.100Z] Info : All sites connected in 2114ms",
		"[2026-10-10T23:24:43.200Z] Info : [netstat -nrv] Destination        Gateway            Flags               Netif Expire",
		"[2026-10-10T23:24:30.906Z] Info : [AWS] [sdp-gw2-aws] Closing *:51996 (Disconnected by gateway)",
		"[2026-10-11T00:00:41.264Z] Info : [GCP] [sdp-gw1-gcp] Closing *:54680 (Dead connection detected)",
		"[2026-09-10T06:30:37.048Z] Info : Closing VPNs: IP address change",
		"[2026-09-10T06:30:39.096Z] Warn : [AWS] [AWS] Failed to connect SPA-UDP socket: Network is unreachable",
		"[2026-10-10T23:24:41.700Z] Info : [AWS] [sdp-gw2-aws] Connected *:50836 --> TLSv1.3://198.18.0.2:443, server version: 6.5.6-45324",
		"[2026-10-10T23:24:41.800Z] Info : ",
	)
	if len(got) != 0 {
		t.Errorf("got %v", got)
	}
}

func TestCRLFLineEndings(t *testing.T) {
	events, err := ParseEvents(loginLine+"\r\n"+renewalLine+"\r\n", "driver.log")
	if err != nil {
		t.Fatal(err)
	}
	want := []kind{{kind: Login, site: "AWS"}, {kind: RenewalNotification, timeLeft: 300 * time.Second}}
	if got := eventKinds(events); !reflect.DeepEqual(got, want) {
		t.Errorf("got %v", got)
	}
}

func TestHalfWrittenLastLineIsSkipped(t *testing.T) {
	events, err := ParseEvents(loginLine+"\n[2026-10-11T00:0", "driver.log")
	if err != nil || len(events) != 1 {
		t.Errorf("events %v, error %v", events, err)
	}
}

func TestCompleteLastLineWithoutNewlineIsParsed(t *testing.T) {
	events, err := ParseEvents(loginLine, "driver.log")
	if err != nil || len(events) != 1 || events[0].Kind != Login {
		t.Errorf("events %v, error %v", events, err)
	}
}

func TestEnvelopeWithEmptyMessage(t *testing.T) {
	// The trailing space after the level's colon can be missing when the message is empty.
	for _, line := range []string{"[2026-10-10T23:24:41.800Z] Info", "[2026-10-10T23:24:41.800Z] Info :"} {
		if _, err := ParseEvents(line+"\n", "driver.log"); err != nil {
			t.Errorf("%q: %v", line, err)
		}
	}
	if _, err := ParseEvents("[2026-10-10T23:24:41.800Z] Info \n", "driver.log"); err == nil {
		t.Error("a level without the colon should fail")
	}
}

func TestUnknownLineFailsWithItsLocation(t *testing.T) {
	text := strings.Join([]string{loginLine, "Oct 10 23:24:41 appgate-driver[123]: Got control connection", renewalLine}, "\n")
	_, err := ParseEvents(text, "driver-2026-10-10.log.gz")
	want := &Error{Kind: UnrecognizedLine, File: "driver-2026-10-10.log.gz", Line: 2,
		Text: "Oct 10 23:24:41 appgate-driver[123]: Got control connection"}
	if !reflect.DeepEqual(err, want) {
		t.Errorf("got %#v", err)
	}
}

func assertUnrecognizedEvent(t *testing.T, lines []string, line int, reason string) {
	t.Helper()
	_, err := ParseEvents(strings.Join(lines, "\n")+"\n", "driver.log")
	var parseErr *Error
	if !errors.As(err, &parseErr) || parseErr.Kind != UnrecognizedEvent {
		t.Fatalf("expected an unrecognized event, got %v", err)
	}
	if parseErr.Line != line || !strings.Contains(parseErr.Reason, reason) {
		t.Errorf("line %d, reason %q", parseErr.Line, parseErr.Reason)
	}
}

func TestRenewalNotificationWithoutTimeLeftFails(t *testing.T) {
	broken := strings.Replace(renewalLine, `"timeLeft":300`, `"secondsLeft":300`, 1)
	assertUnrecognizedEvent(t, []string{loginLine, broken}, 2, "no usable timeLeft")
}

func TestRenewalNotificationWithNonNumericTimeLeftFails(t *testing.T) {
	// The Swift version read a boolean as 0 or 1 here (Foundation bridges JSON
	// booleans to NSNumber). That's not the shape Appgate writes, so it fails.
	for _, value := range []string{`true`, `"300"`, `-1`, `null`} {
		broken := strings.Replace(renewalLine, `"timeLeft":300`, `"timeLeft":`+value, 1)
		assertUnrecognizedEvent(t, []string{broken}, 1, "no usable timeLeft")
	}
}

func TestRenewalNotificationInAnotherShapeFails(t *testing.T) {
	assertUnrecognizedEvent(t, []string{"[2026-10-11T23:19:40.100Z] Info : token-renewal-notification in 300 seconds"}, 1, "isn't the expected send-to reply")
}

func TestLoginThatIsNotJSONFails(t *testing.T) {
	broken := loginLine[:len(loginLine)-5] + ">"
	assertUnrecognizedEvent(t, []string{broken}, 1, "isn't valid JSON")
}

func TestLoginOutsideSendToFails(t *testing.T) {
	unwrapped := `[2026-10-10T23:24:41.741Z] Info : Got request from client <{"jsonrpc":"2.0","id":2,"method":"login","params":{"claimsToken":"*"}}>`
	assertUnrecognizedEvent(t, []string{unwrapped}, 1, "isn't wrapped in send-to")
}

func TestLoginWithoutSiteFails(t *testing.T) {
	broken := strings.Replace(loginLine, `"site-id":"AWS",`, "", 1)
	assertUnrecognizedEvent(t, []string{broken}, 1, "has no site-id")
}

func TestCloseInAnotherShapeFails(t *testing.T) {
	assertUnrecognizedEvent(t, []string{"[2026-10-10T23:24:34.009Z] Info : [AWS] [] Closing *:? Client closed control connection"}, 1, "connection close doesn't look like")
}

func TestImpossibleDateOnAnEventFails(t *testing.T) {
	broken := strings.Replace(loginLine, "2026-10-10T23", "2026-02-30T23", 1)
	assertUnrecognizedEvent(t, []string{broken}, 1, "isn't a real date")
}

func TestImpossibleDateOnNoiseIsIgnored(t *testing.T) {
	if got := kinds(t, "[2026-02-30T23:24:43.100Z] Info : All sites connected in 2114ms"); len(got) != 0 {
		t.Errorf("got %v", got)
	}
}

func TestLeapSecondCarriesIntoTheNextMinute(t *testing.T) {
	events, err := ParseEvents("[2026-12-31T23:59:60.500Z] Info : Got control connection\n", "driver.log")
	if err != nil {
		t.Fatal(err)
	}
	assertDate(t, events[0].Date, utc(t, "2027-01-01T00:00:00.500Z"))
}

func TestCloseReason(t *testing.T) {
	for message, want := range map[string]string{
		"[AWS] [sdp-gw1-aws] Closing *:54679 (Disconnected by gateway)":                      "Disconnected by gateway",
		"[AWS] [] Closing *:0 (Client closed control connection)":                            "Client closed control connection",
		"[AWS] [] Closing *:52253 (Client closed control connection)":                        "Client closed control connection",
		"[GCP] [sdp-gw1-gcp] Closing *:0 (Failed to connect: Failed to send SPA UDP packet)": "Failed to connect: Failed to send SPA UDP packet",
	} {
		if got, ok := closeReason(message); !ok || got != want {
			t.Errorf("%q: got %q, %v", message, got, ok)
		}
	}
	if _, ok := closeReason("Closing VPNs: IP address change"); ok {
		t.Error("not a connection close")
	}
}
