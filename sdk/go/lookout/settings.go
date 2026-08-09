package lookout

// Settings declared as a Go struct, and the manifest schema generated from it.
//
// A plugin declares one group as a field named Settings, whose own fields carry
// their metadata as struct tags:
//
//	type plugin struct {
//		Settings struct {
//			LengthNM float64 `lk:"length_nm" label:"Line length" desc:"How far downwind the line reaches." unit:"nm" min:"0.1" max:"10" default:"1"`
//			Dashed   bool    `lk:"dashed" label:"Dashed" default:"true"`
//		} `label:"Downwind line" tab:"display"`
//	}
//
// The library fills the struct in before OnStart, again on every change, and
// calls OnSettings and then Draw. Read p.Settings.LengthNM; there is nothing to
// parse and nothing to merge.
//
// The same declaration generates the manifest's "settings" object.
// [CheckManifest] fails a plain `go test` when the manifest a plugin ships and
// the struct it reads disagree, so a range cannot drift between the two.
//
// For more than one group, give Settings a struct field per group:
//
//	Settings struct {
//		Alarm  alarmGroup  `label:"Collision alarm" tab:"alarms"`
//		Symbol symbolGroup `label:"Targets" tab:"vessels"`
//	}

import (
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"strconv"
	"strings"
)

// Tab is where a group asks to be shown. The core owns these names.
type Tab string

const (
	TabDisplay     Tab = "display"
	TabDepths      Tab = "depths"
	TabText        Tab = "text"
	TabCharts      Tab = "charts"
	TabVessels     Tab = "vessels"
	TabAlarms      Tab = "alarms"
	TabConnections Tab = "connections"
	TabAdvanced    Tab = "advanced"
)

func (t Tab) valid() bool {
	switch t {
	case TabDisplay, TabDepths, TabText, TabCharts, TabVessels, TabAlarms,
		TabConnections, TabAdvanced:
		return true
	}
	return false
}

// MaxFields is the most settings fields one plugin may declare, counting every
// group and every connection column. The host refuses a manifest with more.
const MaxFields = 16

// MaxTextBytes is the longest text value the host keeps.
const MaxTextBytes = 128

// NumSpec is a number the mariner sets. Unit is shown beside the control; the
// value crosses the API in that unit and is clamped into the range before a
// plugin reads it. Use it to word a connection list's Port column; a settings
// field says the same thing in its tags.
type NumSpec struct {
	Label   string
	Desc    string
	Unit    string
	Min     float64
	Max     float64
	Default float64
}

// FlagSpec is an on/off switch.
type FlagSpec struct {
	Label   string
	Desc    string
	Default bool
}

// TextSpec is a line of text. It is legal only as a column of a connection row:
// a scalar setting crosses the API as a number and the host keeps no scalar
// string.
type TextSpec struct {
	Label string
	Desc  string
	// Default is what a new row starts with.
	Default string
	// Optional lets the mariner leave it empty. An optional column declares no
	// default.
	Optional bool
}

// ---------------------------------------------------------------------------
// One field, read off its tags
// ---------------------------------------------------------------------------

type fieldKind int

const (
	kindNumber fieldKind = iota
	kindToggle
	kindText
)

type specField struct {
	key   string
	label string
	desc  string
	unit  string
	kind  fieldKind

	min, max, def float64
	defBool       bool
	defText       string
	optional      bool

	index int // the field's index in its struct
}

// fieldOf reads one struct field's tags. A field with no lk tag is not a
// setting and answers ok=false.
func fieldOf(f reflect.StructField, i int) (specField, bool, error) {
	key, tagged := f.Tag.Lookup("lk")
	if !tagged || key == "-" {
		return specField{}, false, nil
	}
	if key == "" {
		return specField{}, false, fmt.Errorf("field %s: the lk tag needs the config key", f.Name)
	}
	if !f.IsExported() {
		return specField{}, false, fmt.Errorf("field %s: a settings field must be exported", f.Name)
	}
	s := specField{
		key:   key,
		label: f.Tag.Get("label"),
		desc:  f.Tag.Get("desc"),
		unit:  f.Tag.Get("unit"),
		index: i,
	}
	if s.label == "" {
		return specField{}, false, fmt.Errorf("field %s: needs a label tag", f.Name)
	}

	num := func(tag string) (float64, error) {
		text, ok := f.Tag.Lookup(tag)
		if !ok {
			return 0, fmt.Errorf("field %s: needs a %s tag", f.Name, tag)
		}
		v, err := strconv.ParseFloat(text, 64)
		if err != nil {
			return 0, fmt.Errorf("field %s: %s=%q is not a number", f.Name, tag, text)
		}
		return v, nil
	}

	switch f.Type.Kind() {
	case reflect.Float64, reflect.Float32, reflect.Int, reflect.Int64, reflect.Int32:
		s.kind = kindNumber
		var err error
		if s.min, err = num("min"); err != nil {
			return specField{}, false, err
		}
		if s.max, err = num("max"); err != nil {
			return specField{}, false, err
		}
		if s.def, err = num("default"); err != nil {
			return specField{}, false, err
		}
		if s.min > s.max {
			return specField{}, false, fmt.Errorf("field %s: min is above max", f.Name)
		}
	case reflect.Bool:
		s.kind = kindToggle
		text, ok := f.Tag.Lookup("default")
		if !ok {
			return specField{}, false, fmt.Errorf("field %s: needs a default tag", f.Name)
		}
		v, err := strconv.ParseBool(text)
		if err != nil {
			return specField{}, false, fmt.Errorf("field %s: default=%q is not true or false", f.Name, text)
		}
		s.defBool = v
	case reflect.String:
		s.kind = kindText
		s.optional, _ = strconv.ParseBool(f.Tag.Get("optional"))
		s.defText = f.Tag.Get("default")
	default:
		return specField{}, false, fmt.Errorf("field %s: a settings field must be a number, a bool or a string", f.Name)
	}
	return s, true, nil
}

func numField(key string, n NumSpec) specField {
	return specField{
		key: key, label: n.Label, desc: n.Desc, unit: n.Unit, kind: kindNumber,
		min: n.Min, max: n.Max, def: n.Default, index: -1,
	}
}

func flagField(key string, f FlagSpec) specField {
	return specField{
		key: key, label: f.Label, desc: f.Desc, kind: kindToggle,
		defBool: f.Default, index: -1,
	}
}

func textField(key string, t TextSpec) specField {
	return specField{
		key: key, label: t.Label, desc: t.Desc, kind: kindText,
		defText: t.Default, optional: t.Optional, index: -1,
	}
}

// json writes one field of the schema.
func (s specField) appendJSON(b []byte) []byte {
	b = append(b, `{"key":`...)
	b = appendString(b, s.key)
	b = append(b, `,"label":`...)
	b = appendString(b, s.label)
	if s.desc != "" {
		b = append(b, `,"desc":`...)
		b = appendString(b, s.desc)
	}
	switch s.kind {
	case kindNumber:
		b = append(b, `,"kind":"number"`...)
		if s.unit != "" {
			b = append(b, `,"unit":`...)
			b = appendString(b, s.unit)
		}
		b = append(b, `,"min":`...)
		b = appendNum(b, s.min)
		b = append(b, `,"max":`...)
		b = appendNum(b, s.max)
		b = append(b, `,"default":`...)
		b = appendNum(b, s.def)
	case kindToggle:
		b = append(b, `,"kind":"toggle","default":`...)
		b = appendBool(b, s.defBool)
	case kindText:
		// An optional column declares no default: the shell says the mariner
		// may leave it empty, and empty is what the plugin reads.
		b = append(b, `,"kind":"text"`...)
		if s.optional {
			b = append(b, `,"optional":true`...)
		} else {
			b = append(b, `,"default":`...)
			b = appendString(b, s.defText)
		}
	}
	return append(b, '}')
}

// set writes one value into the struct field this spec came from.
func (s specField) set(v reflect.Value, raw json.RawMessage) {
	switch s.kind {
	case kindNumber:
		var n float64
		if json.Unmarshal(raw, &n) != nil {
			return
		}
		n = clamp(n, s.min, s.max)
		switch v.Kind() {
		case reflect.Int, reflect.Int64, reflect.Int32:
			v.SetInt(int64(n))
		default:
			v.SetFloat(n)
		}
	case kindToggle:
		var b bool
		// A toggle sent as a number is a shell with the wrong type, and is
		// refused rather than coerced.
		if json.Unmarshal(raw, &b) != nil {
			return
		}
		v.SetBool(b)
	case kindText:
		var t string
		if json.Unmarshal(raw, &t) != nil {
			return
		}
		if len(t) > MaxTextBytes {
			t = t[:MaxTextBytes]
		}
		v.SetString(t)
	}
}

func (s specField) setDefault(v reflect.Value) {
	switch s.kind {
	case kindNumber:
		switch v.Kind() {
		case reflect.Int, reflect.Int64, reflect.Int32:
			v.SetInt(int64(s.def))
		default:
			v.SetFloat(s.def)
		}
	case kindToggle:
		v.SetBool(s.defBool)
	case kindText:
		v.SetString(s.defText)
	}
}

// ---------------------------------------------------------------------------
// A group of fields
// ---------------------------------------------------------------------------

type specGroup struct {
	label  string
	tab    Tab
	fields []specField
	// list is set for a connection list group, which carries rows rather than
	// fields.
	list *listSpec
	// at addresses the struct the values live in. It is zero for a schema built
	// from a type alone.
	at reflect.Value
}

type listSpec struct {
	key       string
	footer    string
	empty     string
	addLabel  string
	switchKey string
	columns   []specField
}

// groupOf reads one settings group: the struct's fields, and the label and tab
// off the tag of the field that holds it.
func groupOf(t reflect.Type, tag reflect.StructTag, at reflect.Value) (specGroup, error) {
	g := specGroup{label: tag.Get("label"), tab: Tab(tag.Get("tab")), at: at}
	if g.tab == "" {
		g.tab = TabAdvanced
	}
	if !g.tab.valid() {
		return g, fmt.Errorf("group %q: %q is not a settings tab", g.label, g.tab)
	}
	for i := 0; i < t.NumField(); i++ {
		f := t.Field(i)
		s, ok, err := fieldOf(f, i)
		if err != nil {
			return g, err
		}
		if !ok {
			if f.IsExported() {
				return g, fmt.Errorf("field %s: a settings field needs an lk tag naming its config key", f.Name)
			}
			continue
		}
		if s.kind == kindText {
			return g, fmt.Errorf("field %s is text, which is legal only as a column of a connection row: the host keeps no scalar string", f.Name)
		}
		g.fields = append(g.fields, s)
	}
	return g, nil
}

func (g specGroup) appendJSON(b []byte) []byte {
	b = append(b, `{"label":`...)
	b = appendString(b, g.label)
	b = append(b, `,"tab":`...)
	b = appendString(b, string(g.tab))
	if g.list != nil {
		l := g.list
		b = append(b, `,"list":{"key":`...)
		b = appendString(b, l.key)
		if l.footer != "" {
			b = append(b, `,"footer":`...)
			b = appendString(b, l.footer)
		}
		if l.empty != "" {
			b = append(b, `,"empty":`...)
			b = appendString(b, l.empty)
		}
		if l.addLabel != "" {
			b = append(b, `,"add_label":`...)
			b = appendString(b, l.addLabel)
		}
		b = append(b, `,"switch_key":`...)
		b = appendString(b, l.switchKey)
		b = append(b, `,"item_fields":[`...)
		for i, f := range l.columns {
			if i > 0 {
				b = append(b, ',')
			}
			b = f.appendJSON(b)
		}
		return append(b, `]}}`...)
	}
	b = append(b, `,"fields":[`...)
	for i, f := range g.fields {
		if i > 0 {
			b = append(b, ',')
		}
		b = f.appendJSON(b)
	}
	return append(b, `]}`...)
}

// applyDefaults puts every value at the default its tag names.
func (g specGroup) applyDefaults() {
	if !g.at.IsValid() {
		return
	}
	for _, f := range g.fields {
		f.setDefault(g.at.Field(f.index))
	}
}

// read takes one group's values out of the config object the host sends. A key
// the object does not carry keeps the value already there, so a partial object
// is a partial update rather than a reset to defaults.
func (g specGroup) read(cfg map[string]json.RawMessage) {
	if !g.at.IsValid() {
		return
	}
	for _, f := range g.fields {
		if raw, ok := cfg[f.key]; ok {
			f.set(g.at.Field(f.index), raw)
		}
	}
}

// ---------------------------------------------------------------------------
// A plugin's whole schema
// ---------------------------------------------------------------------------

// settingsOf finds the Settings field on a registered value and reads the
// groups out of it. A value with no Settings field declares no settings.
func settingsOf(p any) ([]specGroup, error) {
	v := reflect.ValueOf(p)
	for v.Kind() == reflect.Pointer {
		if v.IsNil() {
			return nil, errors.New("Register was given a nil pointer")
		}
		v = v.Elem()
	}
	if v.Kind() != reflect.Struct {
		return nil, nil
	}
	f, ok := v.Type().FieldByName("Settings")
	if !ok {
		// The value may be a settings struct itself, which is what
		// SettingsJSON takes when a test checks one group on its own.
		return nil, nil
	}
	if f.Type.Kind() != reflect.Struct {
		return nil, errors.New("the Settings field must be a struct")
	}
	return groupsIn(f.Type, f.Tag, v.FieldByIndex(f.Index))
}

// groupsIn reads either one group of fields, or one group per struct field.
func groupsIn(t reflect.Type, tag reflect.StructTag, at reflect.Value) ([]specGroup, error) {
	structs, scalars := 0, 0
	for i := 0; i < t.NumField(); i++ {
		if !t.Field(i).IsExported() {
			continue
		}
		if t.Field(i).Type.Kind() == reflect.Struct {
			structs++
		} else {
			scalars++
		}
	}
	if structs > 0 && scalars > 0 {
		return nil, errors.New("Settings holds both groups and fields; put every field inside a group")
	}
	if structs == 0 {
		g, err := groupOf(t, tag, at)
		if err != nil {
			return nil, err
		}
		return []specGroup{g}, nil
	}
	var out []specGroup
	for i := 0; i < t.NumField(); i++ {
		f := t.Field(i)
		if !f.IsExported() {
			continue
		}
		var val reflect.Value
		if at.IsValid() {
			val = at.Field(i)
		}
		g, err := groupOf(f.Type, f.Tag, val)
		if err != nil {
			return nil, err
		}
		out = append(out, g)
	}
	return out, nil
}

// schemaOf collects the groups every spec declares. A spec is a plugin value, a
// settings struct, or a connection list.
func schemaOf(specs []any) ([]specGroup, error) {
	var out []specGroup
	for _, s := range specs {
		if c, ok := s.(*Conns); ok {
			g, err := c.group()
			if err != nil {
				return nil, err
			}
			out = append(out, g)
			continue
		}
		groups, err := settingsOf(s)
		if err != nil {
			return nil, err
		}
		if groups == nil {
			// Not a plugin with a Settings field: read the value itself as one
			// group, or as a set of them.
			v := reflect.ValueOf(s)
			for v.Kind() == reflect.Pointer {
				if v.IsNil() {
					return nil, errors.New("SettingsJSON was given a nil pointer")
				}
				v = v.Elem()
			}
			if v.Kind() != reflect.Struct {
				return nil, fmt.Errorf("SettingsJSON: %T is not a settings struct", s)
			}
			groups, err = groupsIn(v.Type(), "", v)
			if err != nil {
				return nil, err
			}
			// A plugin with no settings at all: the value is not a group, it
			// simply declares nothing.
			if fieldCount(groups) == 0 {
				continue
			}
		}
		out = append(out, groups...)
	}
	return out, nil
}

// fieldCount is every field and every column the schema declares, which is what
// the host counts against MaxFields.
func fieldCount(groups []specGroup) int {
	total := 0
	for _, g := range groups {
		if g.list != nil {
			total += len(g.list.columns)
			continue
		}
		total += len(g.fields)
	}
	return total
}

// SettingsJSON is the "settings" value a manifest must carry for these
// declarations. Pass the plugin (its Settings field is read) and every
// connection list it declares:
//
//	b, err := lk.SettingsJSON(&plugin{}, servers)
//
// The result is the JSON to paste into manifest.json. [CheckManifest] compares
// the two for you.
func SettingsJSON(specs ...any) ([]byte, error) {
	groups, err := schemaOf(specs)
	if err != nil {
		return nil, err
	}
	total := fieldCount(groups)
	if total > MaxFields {
		return nil, fmt.Errorf("the settings schema declares %d fields; the host allows %d", total, MaxFields)
	}
	b := append(make([]byte, 0, 512), `{"groups":[`...)
	for i, g := range groups {
		if i > 0 {
			b = append(b, ',')
		}
		b = g.appendJSON(b)
	}
	return append(b, `]}`...), nil
}

// CheckManifest fails when a manifest's "settings" is not the schema these
// declarations generate. Both sides are parsed, so key order and whitespace do
// not matter; everything else does.
//
// For a plugin's own test, which runs on your machine and not in wasm:
//
//	//go:embed manifest.json
//	var manifest []byte
//
//	func TestManifest(t *testing.T) {
//		if err := lk.CheckManifest(manifest, &plugin{}); err != nil {
//			t.Fatal(err)
//		}
//	}
func CheckManifest(manifest []byte, specs ...any) error {
	want, err := SettingsJSON(specs...)
	if err != nil {
		return err
	}
	var doc struct {
		Settings json.RawMessage `json:"settings"`
	}
	if err := json.Unmarshal(manifest, &doc); err != nil {
		return fmt.Errorf("the manifest is not JSON: %w", err)
	}
	if len(doc.Settings) == 0 {
		if string(want) == `{"groups":[]}` {
			// Nothing declared on either side: a plugin with no settings needs
			// no settings block.
			return nil
		}
		return fmt.Errorf("the manifest declares no settings; the struct declares:\n%s", want)
	}
	var got, expected any
	if err := json.Unmarshal(doc.Settings, &got); err != nil {
		return fmt.Errorf("the manifest's settings are not JSON: %w", err)
	}
	if err := json.Unmarshal(want, &expected); err != nil {
		return err
	}
	if !sameJSON(got, expected) {
		return fmt.Errorf("the manifest's settings are not what the struct declares.\nthe struct declares:\n%s\nthe manifest carries:\n%s",
			want, strings.TrimSpace(string(doc.Settings)))
	}
	return nil
}

// sameJSON is deep equality over parsed JSON. Numbers compare by value, so 926
// and 926.0 are the same schema.
func sameJSON(a, b any) bool {
	switch x := a.(type) {
	case nil:
		return b == nil
	case bool:
		y, ok := b.(bool)
		return ok && x == y
	case float64:
		y, ok := b.(float64)
		return ok && x == y
	case string:
		y, ok := b.(string)
		return ok && x == y
	case []any:
		y, ok := b.([]any)
		if !ok || len(x) != len(y) {
			return false
		}
		for i := range x {
			if !sameJSON(x[i], y[i]) {
				return false
			}
		}
		return true
	case map[string]any:
		y, ok := b.(map[string]any)
		if !ok || len(x) != len(y) {
			return false
		}
		for k, v := range x {
			w, ok := y[k]
			if !ok || !sameJSON(v, w) {
				return false
			}
		}
		return true
	}
	return false
}
