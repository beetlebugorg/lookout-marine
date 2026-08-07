//go:build !wasip1

// The host boundary on a target that has no host. A plugin is built for
// wasip1; this file exists so the package compiles and its tests run on a
// development machine, where it stands in as a recording fake.
//
// `go test ./...` drives a whole plugin through dispatchStart and
// dispatchEvent and then reads what the plugin asked the host to do out of
// testHost. The real boundary is host_wasip1.go, and the two files declare the
// same functions.

package lookout

import "strings"

// testHost records what the library sent and answers what a test set. Reset it
// at the top of each test.
type recordingHost struct {
	Now  int64 // what NowMs answers, milliseconds since the epoch
	Mono int64 // what MonoMs answers

	Logs      []string
	Overlays  []string
	Statuses  []string
	Publishes []string
	Upserts   []string
	Alerts    []string
	Subscribe []string

	// Timers, connections and sockets get ids from these counters, so a test
	// knows what the library was handed.
	NextTimer int64
	Timers    map[int64]int64 // id -> delay in ms
	Periodic  map[int64]bool
	Cancelled []int64

	NextConn int64
	Dialled  []string // "host:port" per tcp_connect, "ws <url>" per ws_connect
	Sent     map[int64][]string
	Closed   []int64

	// RefuseDial makes the next dial answer -1, the way the host answers a
	// call the manifest's grants do not cover.
	RefuseDial bool
}

var testHost = newRecordingHost()

func newRecordingHost() *recordingHost {
	return &recordingHost{
		Now:      1_700_000_000_000,
		Timers:   map[int64]int64{},
		Periodic: map[int64]bool{},
		Sent:     map[int64][]string{},
	}
}

func resetHost() {
	testHost = newRecordingHost()
	resetRegistry()
}

func hostLog(level Level, msg string) {
	testHost.Logs = append(testHost.Logs, levelName(level)+" "+msg)
}

func levelName(l Level) string {
	switch l {
	case Debug:
		return "debug"
	case Info:
		return "info"
	case Warn:
		return "warn"
	default:
		return "error"
	}
}

func hostNow() int64  { return testHost.Now }
func hostMono() int64 { return testHost.Mono }

func hostPublish(b []byte) int32 {
	testHost.Publishes = append(testHost.Publishes, string(b))
	return 0
}

func hostAISUpsert(b []byte) int32 {
	testHost.Upserts = append(testHost.Upserts, string(b))
	return 0
}

func hostOverlay(b []byte) int32 {
	testHost.Overlays = append(testHost.Overlays, string(b))
	return 0
}

func hostStatus(b []byte) { testHost.Statuses = append(testHost.Statuses, string(b)) }

func hostAlert(b []byte) int32 {
	testHost.Alerts = append(testHost.Alerts, string(b))
	return 0
}

func hostSubscribe(b []byte) int32 {
	testHost.Subscribe = append(testHost.Subscribe, string(b))
	return 0
}

func hostAISSubscribe() int32 { return 0 }

func hostTimerSet(delayMs int64, periodic bool) int64 {
	testHost.NextTimer++
	id := testHost.NextTimer
	testHost.Timers[id] = delayMs
	testHost.Periodic[id] = periodic
	return id
}

func hostTimerCancel(id int64) { testHost.Cancelled = append(testHost.Cancelled, id) }

func hostTCPConnect(addr string, port uint16) int64 {
	if testHost.RefuseDial {
		return -1
	}
	testHost.NextConn++
	testHost.Dialled = append(testHost.Dialled, addr+":"+itoa(int64(port)))
	return testHost.NextConn
}

func hostTCPSend(id int64, b []byte) int32 {
	testHost.Sent[id] = append(testHost.Sent[id], string(b))
	return int32(len(b))
}

func hostTCPClose(id int64) { testHost.Closed = append(testHost.Closed, id) }

func hostWSConnect(req []byte) int64 {
	if testHost.RefuseDial {
		return -1
	}
	testHost.NextConn++
	testHost.Dialled = append(testHost.Dialled, "ws "+string(req))
	return testHost.NextConn
}

func hostWSSend(id int64, b []byte) int32 { return hostTCPSend(id, b) }
func hostWSClose(id int64)                { hostTCPClose(id) }

func hostUDPOpen(port uint16) int64                               { return -1 }
func hostUDPSend(id int64, b []byte, addr string, p uint16) int32 { return -1 }
func hostUDPClose(id int64)                                       {}
func hostHTTPFetch(req []byte) int64                              { return -1 }
func hostStorageGet(key string, out []byte) int32                 { return -1 }
func hostStoragePut(key string, value []byte) int32               { return -1 }
func hostFileRead(handle, offset int64, out []byte) int32         { return -1 }
func hostFileWrite(handle int64, b []byte) int32                  { return -1 }
func hostFileClose(handle int64)                                  {}

func itoa(v int64) string {
	if v == 0 {
		return "0"
	}
	neg := v < 0
	if neg {
		v = -v
	}
	var d [20]byte
	i := len(d)
	for v > 0 {
		i--
		d[i] = byte('0' + v%10)
		v /= 10
	}
	if neg {
		i--
		d[i] = '-'
	}
	return string(d[i:])
}

// lastStatus is what the chrome would be showing, for a test to assert on.
func lastStatus() string {
	if len(testHost.Statuses) == 0 {
		return ""
	}
	return testHost.Statuses[len(testHost.Statuses)-1]
}

// lastOverlay is the most recent batch the library sent.
func lastOverlay() string {
	if len(testHost.Overlays) == 0 {
		return ""
	}
	return testHost.Overlays[len(testHost.Overlays)-1]
}

func logsWith(substr string) []string {
	var out []string
	for _, l := range testHost.Logs {
		if strings.Contains(l, substr) {
			out = append(out, l)
		}
	}
	return out
}
