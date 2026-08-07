// Windline in Go: one dashed line downwind from own ship, 1 nm long.
//
// The same plugin as the Zig walkthrough in
// docs/developer-guide/plugins/build-your-first.md, so the two languages can be
// read side by side. The library subscribes, ages both readings against the 5 s
// window, runs Draw once a second, and takes the line off the chart and says
// which instrument is missing when either one goes stale.
//
// Build (Go 1.24 or later), from this directory:
//
//	GOOS=wasip1 GOARCH=wasm go build -buildmode=c-shared \
//	    -o org.example.windline.go.wasm .
package main

import lk "github.com/beetlebugorg/lookout-marine/sdk/go/lookout"

var (
	boat = lk.SubscribePosition("navigation.position")
	twd  = lk.SubscribeNumber("environment.wind.directionTrue", lk.InputOpts{Label: "wind"})
)

type windline struct{}

// Registration happens here because a reactor module never runs main.
func init() { lk.Register(&windline{}) }

func main() {}

func (p *windline) Draw(c *lk.Chart) {
	from := boat.Get()
	// The wind direction is where the wind blows FROM, so downwind is the
	// reciprocal.
	to := from.Destination(twd.Get()+180, lk.NM(1))
	c.Line("windline", []lk.Point{from, to}, lk.Line{Color: lk.ColorWarning, Dash: true})
}
