// Windline in Go: one dashed line downwind from own ship, 1 nm long.
//
// The same plugin as the Zig walkthrough in
// docs/developer-guide/plugins/build-your-first.md, so the two languages can be
// read side by side. It keeps the last position and the last true wind in
// package variables and redraws from a 1 Hz timer, because the store fans out
// at up to 10 Hz and a line that twitches ten times a second is harder to read
// than one that steps once a second. Data older than the 5 s staleness window
// takes the line off the chart.
//
// Build (Go 1.24 or later):
//
//	GOOS=wasip1 GOARCH=wasm go build -buildmode=c-shared \
//	    -o org.example.windline.go.wasm .
//	cp org.example.windline.go.wasm manifest.json ../../../../zig-out/plugins/
//	mv ../../../../zig-out/plugins/manifest.json \
//	   ../../../../zig-out/plugins/org.example.windline.go.manifest.json
package main

import (
	"errors"
	"fmt"
	"math"
	"time"

	lk "github.com/beetlebugorg/lookout-marine/sdk/go/lookout"
)

const (
	lineID       = "windline"
	maxAgeMs     = 5000
	redrawMs     = 1000
	lengthM      = 1852.0
	earthRadiusM = 6371008.8
)

// A value and enough to age it between events: the host stamps AgeMs at
// delivery, and the monotonic clock carries it on from there.
type sample struct {
	have    bool
	atMono  int64
	ageAtMs int64
}

func (s *sample) stamp(ageMs int64) {
	s.have = true
	s.atMono = lk.MonoMs()
	s.ageAtMs = ageMs
}

func (s sample) fresh(monoMs int64) bool {
	return s.have && s.ageAtMs+(monoMs-s.atMono) <= maxAgeMs
}

type windline struct {
	pos      sample
	lat, lon float64

	wind   sample
	twdDeg float64

	timerID int64
	drawn   bool

	// The chrome only hears about a change of state: the host logs every
	// status line it has not seen, so a 1 Hz repeat would be a 1 Hz log line.
	state string
}

// Registration happens here because a reactor module never runs main.
func init() { lk.Register(&windline{timerID: -1, state: "starting"}) }

func main() {}

func (p *windline) say(next, detail string) {
	if p.state == next {
		return
	}
	p.state = next
	lk.Status(next, detail)
}

func (p *windline) Start(s lk.Start) error {
	if lk.SubscribePaths("navigation.position", "environment.wind.directionTrue") < 0 {
		return errors.New("subscribe refused")
	}
	p.timerID = lk.TimerSet(redrawMs, true)
	if p.timerID < 0 {
		return errors.New("timer refused")
	}
	// The floor the host gives Go, demonstrated in one line: the runtime is
	// up, the clock answers, and a Println goes to this plugin's log rather
	// than to the app's terminal. Everything else the standard library can
	// reach — files, sockets, environment variables, threads — is refused.
	fmt.Printf("windline (go): runtime is up, epoch %d ms, host %d ms\n",
		time.Now().UnixMilli(), lk.NowMs())

	lk.Status("starting", "waiting for wind and position")
	return nil
}

func (p *windline) OnEvent(e lk.Event) error {
	switch e.Kind {
	case lk.StoreChanged:
		p.take(e)
	case lk.Timer:
		if e.Handle == p.timerID {
			p.redraw()
		}
	case lk.Shutdown:
		if p.timerID >= 0 {
			lk.TimerCancel(p.timerID)
		}
		p.clearLine()
		p.say("stopped", "shut down")
	}
	return nil
}

// Record what the store sent. Nothing draws here; the timer does that.
func (p *windline) take(e lk.Event) {
	for _, r := range e.Readings() {
		switch r.Path {
		case "navigation.position":
			if r.Removed() {
				p.pos.have = false
				continue
			}
			lat, lon, ok := r.Position()
			if !ok {
				continue
			}
			p.lat, p.lon = lat, lon
			p.pos.stamp(r.AgeMs)
		case "environment.wind.directionTrue":
			if r.Removed() {
				p.wind.have = false
				continue
			}
			v, ok := r.Number()
			if !ok || math.IsNaN(v) || math.IsInf(v, 0) {
				continue
			}
			p.twdDeg = v
			p.wind.stamp(r.AgeMs)
		}
	}
}

func (p *windline) redraw() {
	mono := lk.MonoMs()
	if !p.pos.fresh(mono) || !p.wind.fresh(mono) {
		p.clearLine()
		p.say("degraded", "no wind or no position")
		return
	}

	// The wind direction is where the wind blows FROM, so downwind is the
	// reciprocal.
	endLon, endLat := destination(p.lat, p.lon, p.twdDeg+180.0, lengthM)
	ov := lk.NewOverlay()
	ov.Polyline(lineID, [][2]float64{{p.lon, p.lat}, {endLon, endLat}}, 1.5, lk.ColorWarning, true)
	if ov.Send() < 0 {
		return
	}
	p.drawn = true
	p.say("running", "downwind line drawn")
}

// Take the line off the chart. Idempotent: nothing is sent once it is gone.
func (p *windline) clearLine() {
	if !p.drawn {
		return
	}
	ov := lk.NewOverlay()
	ov.Del(lineID)
	ov.Send()
	p.drawn = false
}

// Great-circle destination, returned as lon, lat. A sphere, not the ellipsoid
// the chart is drawn on: the error over 1 nm is under 4 m.
func destination(fromLat, fromLon, bearingDeg, distanceM float64) (lon, lat float64) {
	lat1 := fromLat * math.Pi / 180
	lon1 := fromLon * math.Pi / 180
	brg := bearingDeg * math.Pi / 180
	d := distanceM / earthRadiusM
	lat2 := math.Asin(math.Sin(lat1)*math.Cos(d) + math.Cos(lat1)*math.Sin(d)*math.Cos(brg))
	lon2 := lon1 + math.Atan2(
		math.Sin(brg)*math.Sin(d)*math.Cos(lat1),
		math.Cos(d)-math.Sin(lat1)*math.Sin(lat2),
	)
	return lon2 * 180 / math.Pi, lat2 * 180 / math.Pi
}
