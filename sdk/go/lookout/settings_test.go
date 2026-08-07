//go:build !wasip1

// The library's own tests run on a development machine, against the
// recording host in host_native.go. Nothing here is built into a plugin.

package lookout

import (
	"encoding/json"
	"strings"
	"testing"
)

// The ais plugin's first group, as Zig declares it, so the two languages can be
// checked against the same manifest text.
type alarmSettings struct {
	CPALimit float64 `lk:"cpa_limit" label:"Closest approach (CPA)" desc:"Alarm when a vessel will pass closer than this." unit:"m" min:"93" max:"9260" default:"926"`
	CPAAlarm bool    `lk:"cpa_alarm" label:"Collision alarm" desc:"Sound the alarm and colour the vessel red. Off silences both." default:"true"`
}

type alarmPlugin struct {
	Settings alarmSettings `label:"Collision alarm" tab:"alarms"`
}

func (p *alarmPlugin) Draw(c *Chart) {}

func sameSchema(t *testing.T, got []byte, want string) {
	t.Helper()
	var a, b any
	if err := json.Unmarshal(got, &a); err != nil {
		t.Fatalf("the schema is not JSON: %v\n%s", err, got)
	}
	if err := json.Unmarshal([]byte(want), &b); err != nil {
		t.Fatalf("the fixture is not JSON: %v", err)
	}
	if !sameJSON(a, b) {
		t.Fatalf("the schema is not the fixture.\ngot:  %s\nwant: %s", got, want)
	}
}

func TestTheGeneratedSchemaIsTheManifestTheAisPluginShips(t *testing.T) {
	got, err := SettingsJSON(&alarmPlugin{})
	if err != nil {
		t.Fatal(err)
	}
	sameSchema(t, got, `{"groups":[{"label":"Collision alarm","tab":"alarms","fields":[
		{"key":"cpa_limit","label":"Closest approach (CPA)","desc":"Alarm when a vessel will pass closer than this.","kind":"number","unit":"m","min":93,"max":9260,"default":926},
		{"key":"cpa_alarm","label":"Collision alarm","desc":"Sound the alarm and colour the vessel red. Off silences both.","kind":"toggle","default":true}]}]}`)
}

func TestTheValuesStartAtTheDefaultsTheTagsName(t *testing.T) {
	resetHost()
	p := &alarmPlugin{}
	Register(p)
	if p.Settings.CPALimit != 926 || !p.Settings.CPAAlarm {
		t.Fatalf("defaults not applied: %+v", p.Settings)
	}
}

func TestAConfigObjectUpdatesTheKeysItCarriesAndLeavesTheRest(t *testing.T) {
	resetHost()
	p := &alarmPlugin{}
	Register(p)
	readSettings(configOf([]byte(`{"cpa_limit":1500}`)))
	if p.Settings.CPALimit != 1500 || !p.Settings.CPAAlarm {
		t.Fatalf("a partial object is a partial update: %+v", p.Settings)
	}
}

func TestANumberOutsideTheDeclaredRangeIsClampedAndAToggleOfTheWrongTypeIsRefused(t *testing.T) {
	resetHost()
	p := &alarmPlugin{}
	Register(p)
	readSettings(configOf([]byte(`{"cpa_limit":99999,"cpa_alarm":42}`)))
	if p.Settings.CPALimit != 9260 {
		t.Fatalf("want the maximum, got %v", p.Settings.CPALimit)
	}
	if !p.Settings.CPAAlarm {
		t.Fatal("a toggle sent as a number is a shell with the wrong type, and is refused")
	}
}

func TestAGroupWithNoTabLandsOnAdvancedAndAnEmptyDescIsLeftOut(t *testing.T) {
	type bare struct {
		Scale float64 `lk:"scale" label:"Size" min:"0.5" max:"3" default:"1"`
	}
	got, err := SettingsJSON(&bare{})
	if err != nil {
		t.Fatal(err)
	}
	want := `{"groups":[{"label":"","tab":"advanced","fields":[` +
		`{"key":"scale","label":"Size","kind":"number","min":0.5,"max":3,"default":1}]}]}`
	if string(got) != want {
		t.Fatalf("got  %s\nwant %s", got, want)
	}
}

func TestALabelWithAQuoteInItIsEscapedRatherThanClosingTheString(t *testing.T) {
	type quoted struct {
		X bool `lk:"x" label:"The \"big\" switch" default:"false"`
	}
	got, err := SettingsJSON(&quoted{})
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Groups []struct {
			Fields []struct {
				Label string `json:"label"`
			} `json:"fields"`
		} `json:"groups"`
	}
	if err := json.Unmarshal(got, &doc); err != nil {
		t.Fatalf("the schema is not JSON: %v\n%s", err, got)
	}
	if doc.Groups[0].Fields[0].Label != `The "big" switch` {
		t.Fatalf("the quote was not escaped: %s", got)
	}
}

func TestTwoGroupsAreDeclaredAsTwoStructs(t *testing.T) {
	type first struct {
		A float64 `lk:"a" label:"A" min:"0" max:"1" default:"0"`
	}
	type second struct {
		B bool `lk:"b" label:"B" default:"true"`
	}
	type plugin struct {
		Settings struct {
			First  first  `label:"First" tab:"display"`
			Second second `label:"Second" tab:"alarms"`
		}
	}
	p := &plugin{}
	got, err := SettingsJSON(p)
	if err != nil {
		t.Fatal(err)
	}
	sameSchema(t, got, `{"groups":[
		{"label":"First","tab":"display","fields":[{"key":"a","label":"A","kind":"number","min":0,"max":1,"default":0}]},
		{"label":"Second","tab":"alarms","fields":[{"key":"b","label":"B","kind":"toggle","default":true}]}]}`)

	// Both groups read from the one flat config object the host sends.
	resetHost()
	Register(p)
	readSettings(configOf([]byte(`{"a":0.5,"b":false}`)))
	if p.Settings.First.A != 0.5 || p.Settings.Second.B {
		t.Fatalf("groups did not read: %+v", p.Settings)
	}
}

func TestTextIsRefusedOutsideAConnectionRow(t *testing.T) {
	type plugin struct {
		Settings struct {
			Name string `lk:"name" label:"Name"`
		}
	}
	_, err := SettingsJSON(&plugin{})
	if err == nil || !strings.Contains(err.Error(), "connection row") {
		t.Fatalf("want the text refusal, got %v", err)
	}
}

func TestAFieldWithNoTagIsAMistakeAndSaysSo(t *testing.T) {
	type plugin struct {
		Settings struct {
			Length float64
		}
	}
	_, err := SettingsJSON(&plugin{})
	if err == nil || !strings.Contains(err.Error(), "lk tag") {
		t.Fatalf("want the missing-tag error, got %v", err)
	}
}

func TestMoreFieldsThanTheHostAllowsIsRefused(t *testing.T) {
	type wide struct {
		A bool `lk:"a" label:"a" default:"true"`
		B bool `lk:"b" label:"b" default:"true"`
		C bool `lk:"c" label:"c" default:"true"`
		D bool `lk:"d" label:"d" default:"true"`
		E bool `lk:"e" label:"e" default:"true"`
		F bool `lk:"f" label:"f" default:"true"`
		G bool `lk:"g" label:"g" default:"true"`
		H bool `lk:"h" label:"h" default:"true"`
		I bool `lk:"i" label:"i" default:"true"`
		J bool `lk:"j" label:"j" default:"true"`
		K bool `lk:"k" label:"k" default:"true"`
		L bool `lk:"l" label:"l" default:"true"`
		M bool `lk:"m" label:"m" default:"true"`
		N bool `lk:"n" label:"n" default:"true"`
		O bool `lk:"o" label:"o" default:"true"`
		P bool `lk:"p" label:"p" default:"true"`
		Q bool `lk:"q" label:"q" default:"true"`
	}
	_, err := SettingsJSON(&wide{})
	if err == nil || !strings.Contains(err.Error(), "17 fields") {
		t.Fatalf("want the field-count refusal, got %v", err)
	}
}

func TestCheckManifestFailsOnADriftedRange(t *testing.T) {
	manifest := []byte(`{"id":"x","abi":1,"settings":{"groups":[{"label":"Collision alarm","tab":"alarms","fields":[
		{"key":"cpa_limit","label":"Closest approach (CPA)","desc":"Alarm when a vessel will pass closer than this.","kind":"number","unit":"m","min":93,"max":9260,"default":926},
		{"key":"cpa_alarm","label":"Collision alarm","desc":"Sound the alarm and colour the vessel red. Off silences both.","kind":"toggle","default":true}]}]}}`)
	if err := CheckManifest(manifest, &alarmPlugin{}); err != nil {
		t.Fatalf("the manifest matches the struct: %v", err)
	}

	drifted := []byte(strings.Replace(string(manifest), `"max":9260`, `"max":5000`, 1))
	if err := CheckManifest(drifted, &alarmPlugin{}); err == nil {
		t.Fatal("a range that drifted must fail the check")
	}
}
