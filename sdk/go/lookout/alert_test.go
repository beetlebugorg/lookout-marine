//go:build !wasip1

package lookout

import (
	"testing"
)

// The payload an alert goes out as. The key is what lets the host recognise an
// alert it is already holding, so a plugin that restates a danger does not
// raise a second one over the mariner's acknowledgement.

func TestAnAlertCarriesItsKey(t *testing.T) {
	want := `{"severity":"alarm","key":"cpa:899000101",` +
		`"title":"AIS CPA alarm","body":"GALLEON is closing"}`
	if got := string(alertPayload("cpa:899000101", Alarm, "AIS CPA alarm", "GALLEON is closing")); got != want {
		t.Fatalf("the keyed payload is %s, want %s", got, want)
	}
}

func TestAnAlertWithNoKeySendsTheSamePayloadItAlwaysDid(t *testing.T) {
	want := `{"severity":"alarm","title":"AIS CPA alarm","body":"GALLEON is closing"}`
	if got := string(alertPayload("", Alarm, "AIS CPA alarm", "GALLEON is closing")); got != want {
		t.Fatalf("the unkeyed payload is %s, want %s", got, want)
	}
}

func TestAlertKeyedReachesTheHost(t *testing.T) {
	resetHost()
	if rc := AlertKeyed("cpa:899000101", Alarm, "AIS CPA alarm", "GALLEON is closing"); rc != 0 {
		t.Fatalf("the raise answered %d", rc)
	}
	if len(testHost.Alerts) != 1 {
		t.Fatalf("want one alert, got %v", testHost.Alerts)
	}
}
