//go:build !wasip1

// The library's own tests run on a development machine, against the
// recording host in host_native.go. Nothing here is built into a plugin.

package lookout

import (
	"encoding/json"
	"strings"
	"testing"
)

// A tier-2 plugin, shaped like signalk: two transports, one column that picks
// between them, and per-connection state the parser keeps.

type server struct {
	// A column: an exported field with an lk tag. The library fills it in.
	WebSocket bool `lk:"websocket" label:"WebSocket" desc:"Read the WebSocket stream instead of the plain one." default:"false"`
	// State: everything else on the struct. The library leaves it alone.
	docs int
}

type skPlugin struct {
	opened []string
	closed []string
	data   []string
}

func (p *skPlugin) Endpoint(conn *Conn) Endpoint {
	if conn.State.(*server).WebSocket {
		return WSEndpoint("ws://" + conn.Host + "/signalk/v1/stream")
	}
	return TCPEndpoint(conn.Host, conn.Port)
}

func (p *skPlugin) OnOpen(conn *Conn) {
	p.opened = append(p.opened, conn.ID)
	conn.Send([]byte("subscribe"))
}

func (p *skPlugin) OnClose(conn *Conn) { p.closed = append(p.closed, conn.ID) }

func (p *skPlugin) OnData(conn *Conn, data []byte) {
	conn.State.(*server).docs++
	conn.Count(1)
	p.data = append(p.data, conn.ID+":"+string(data))
}

func (p *skPlugin) ConnNote(conn *Conn) string {
	if conn.State.(*server).docs == 0 {
		return "nothing parsed yet"
	}
	return ""
}

func newServers() *Conns {
	return Connections(ConnOpts{
		Key:      "servers",
		Group:    "Signal K servers",
		AddLabel: "Add Server",
		RateNoun: "deltas",
		Columns: RowColumns{
			Port: NumSpec{Label: "Port", Desc: "Most Signal K servers stream on port 8375.", Min: 1, Max: 65535, Default: 8375},
		},
		Discover:       []Discover{{Service: "_signalk-ws._tcp", Set: `{"websocket":true}`}},
		State:          func() any { return &server{} },
		StatusEmpty:    "no servers",
		RefusedDetail:  "websocket refused; the server is not on this boat's network",
		NoAnswerDetail: "check the address",
	})
}

const twoServers = `{"servers":[
	{"id":"a","name":"Boat","host":"10.0.0.2","port":8375,"enabled":true},
	{"id":"b","host":"laptop.local","port":3000,"websocket":true,"enabled":true}]}`

func startServers(t *testing.T, cfg string) (*skPlugin, *Conns) {
	t.Helper()
	resetHost()
	c := newServers()
	p := &skPlugin{}
	Register(p)
	if rc := dispatchStart([]byte(`{"abi":1,"config":` + cfg + `}`)); rc != 0 {
		t.Fatalf("lk_start answered %d: %v", rc, testHost.Logs)
	}
	return p, c
}

type statusLine struct {
	State  string `json:"state"`
	Detail string `json:"detail"`
	Items  []struct {
		ID     string `json:"id"`
		State  string `json:"state"`
		Detail string `json:"detail"`
	} `json:"items"`
}

func status(t *testing.T) statusLine {
	t.Helper()
	var s statusLine
	if err := json.Unmarshal([]byte(lastStatus()), &s); err != nil {
		t.Fatalf("the status is not JSON: %v\n%s", err, lastStatus())
	}
	return s
}

func TestEachConnectionIsDialledWhereItsColumnsSay(t *testing.T) {
	_, c := startServers(t, twoServers)

	if len(c.All()) != 2 {
		t.Fatalf("want two connections, got %d", len(c.All()))
	}
	want := []string{
		"10.0.0.2:8375",
		`ws {"url":"ws://laptop.local/signalk/v1/stream"}`,
	}
	if len(testHost.Dialled) != 2 || testHost.Dialled[0] != want[0] || testHost.Dialled[1] != want[1] {
		t.Fatalf("dialled %v, want %v", testHost.Dialled, want)
	}
	if c.ByID("a").Label() != "Boat" || c.ByID("b").Label() != "laptop.local" {
		t.Fatal("a connection with no name is called by its address")
	}
}

func TestAStreamThatOpensCarriesDataToTheRightConnection(t *testing.T) {
	p, c := startServers(t, twoServers)
	a, b := c.ByID("a"), c.ByID("b")

	dispatchEvent(TCPConnected, a.sock, nil)
	dispatchEvent(WSOpen, b.sock, []byte(`{"protocol":""}`))
	if len(p.opened) != 2 {
		t.Fatalf("both streams opened: %v", p.opened)
	}
	if got := testHost.Sent[a.sock]; len(got) != 1 || got[0] != "subscribe" {
		t.Fatalf("OnOpen must be able to write to the connection: %v", got)
	}

	dispatchEvent(TCPData, a.sock, []byte("delta-a"))
	dispatchEvent(WSData, b.sock, []byte("delta-b"))
	if len(p.data) != 2 || p.data[0] != "a:delta-a" || p.data[1] != "b:delta-b" {
		t.Fatalf("the bytes reached %v", p.data)
	}
	if a.State.(*server).docs != 1 || b.State.(*server).docs != 1 {
		t.Fatal("each connection keeps its own state")
	}

	// The rate is counted over the status window: two deltas in a 2 s window is
	// one a second.
	dispatchEvent(TCPData, a.sock, []byte("delta-a2"))
	dispatchEvent(Timer, c.statusTimer, nil)
	s := status(t)
	if s.State != "running" || s.Detail != "2 of 2 connected, 2 deltas/s" {
		t.Fatalf("the plugin line is %q", s.Detail)
	}
	if len(s.Items) != 2 || s.Items[0].ID != "a" || s.Items[0].Detail != "1 deltas/s" {
		t.Fatalf("the row items are %+v", s.Items)
	}
}

func TestPausingAConnectionClosesItAndLeavesTheOtherAlone(t *testing.T) {
	p, c := startServers(t, twoServers)
	a := c.ByID("a")
	dispatchEvent(TCPConnected, a.sock, nil)
	sockA := a.sock

	paused := strings.Replace(twoServers, `"id":"a","name":"Boat","host":"10.0.0.2","port":8375,"enabled":true`,
		`"id":"a","name":"Boat","host":"10.0.0.2","port":8375,"enabled":false`, 1)
	dispatchEvent(ConfigChanged, 0, []byte(paused))

	if len(testHost.Closed) != 1 || testHost.Closed[0] != sockA {
		t.Fatalf("only the paused connection's socket closes: %v", testHost.Closed)
	}
	if c.ByID("a").conn != RowPaused {
		t.Fatalf("connection a reads %q", c.ByID("a").conn)
	}
	if len(testHost.Dialled) != 2 {
		t.Fatalf("editing one connection redialled another: %v", testHost.Dialled)
	}
	if len(p.closed) != 0 {
		t.Fatal("a socket the library closed is not a stream that ended")
	}
	s := status(t)
	if s.Items[0].State != "paused" || s.Detail != "0 of 2 connected" {
		t.Fatalf("the status is %+v", s)
	}
}

func TestANewAddressRedialsAndResetsTheState(t *testing.T) {
	_, c := startServers(t, twoServers)
	a := c.ByID("a")
	dispatchEvent(TCPConnected, a.sock, nil)
	dispatchEvent(TCPData, a.sock, []byte("delta"))
	if a.State.(*server).docs != 1 {
		t.Fatal("the connection parsed one document")
	}

	moved := strings.Replace(twoServers, `"host":"10.0.0.2"`, `"host":"10.0.0.9"`, 1)
	dispatchEvent(ConfigChanged, 0, []byte(moved))

	if got := testHost.Dialled[len(testHost.Dialled)-1]; got != "10.0.0.9:8375" {
		t.Fatalf("the new address was not dialled: %v", testHost.Dialled)
	}
	if c.ByID("a").State.(*server).docs != 0 {
		t.Fatal("a connection that moved starts its state over")
	}
}

func TestAColumnThatPicksTheTransportIsAChangeOfAddress(t *testing.T) {
	_, c := startServers(t, twoServers)
	dialled := len(testHost.Dialled)

	switched := strings.Replace(twoServers, `"port":8375,"enabled":true`,
		`"port":8375,"websocket":true,"enabled":true`, 1)
	dispatchEvent(ConfigChanged, 0, []byte(switched))

	if len(testHost.Dialled) != dialled+1 {
		t.Fatalf("a changed column must redial: %v", testHost.Dialled)
	}
	if got := testHost.Dialled[len(testHost.Dialled)-1]; !strings.HasPrefix(got, "ws ") {
		t.Fatalf("the connection moved to the websocket: %s", got)
	}
	if !c.ByID("a").State.(*server).WebSocket {
		t.Fatal("the column value did not reach the connection")
	}
}

func TestADeletedConnectionTakesItsStreamWithIt(t *testing.T) {
	_, c := startServers(t, twoServers)
	sockB := c.ByID("b").sock

	dispatchEvent(ConfigChanged, 0, []byte(`{"servers":[{"id":"a","name":"Boat","host":"10.0.0.2","port":8375,"enabled":true}]}`))
	if len(c.All()) != 1 || c.ByID("b") != nil {
		t.Fatalf("connection b is gone: %d connections", len(c.All()))
	}
	if len(testHost.Closed) != 1 || testHost.Closed[0] != sockB {
		t.Fatalf("connection b's socket closes: %v", testHost.Closed)
	}
}

func TestAConnectionThatNeverAnswersReadsAsUnreachable(t *testing.T) {
	p, c := startServers(t, `{"servers":[{"id":"a","host":"10.0.0.2","port":8375,"enabled":true}]}`)
	a := c.ByID("a")

	// Three closes in a row, each one retried on the library's clock.
	for i := 0; i < 3; i++ {
		dispatchEvent(TCPClosed, a.sock, nil)
		if a.retryTimer < 0 {
			t.Fatalf("a dropped connection must be retried (try %d)", i)
		}
		dispatchEvent(Timer, a.retryTimer, nil)
	}
	if a.conn != RowNoAnswer {
		t.Fatalf("after three failures the connection reads %q", a.conn)
	}
	if len(p.closed) != 3 {
		t.Fatalf("the plugin heard %d closes", len(p.closed))
	}
	s := status(t)
	if s.Items[0].State != "unreachable" || s.Items[0].Detail != "check the address" {
		t.Fatalf("the row line is %+v", s.Items[0])
	}
}

func TestAnAddressTheHostWillNotDialStopsRetrying(t *testing.T) {
	resetHost()
	testHost.RefuseDial = true
	c := newServers()
	Register(&skPlugin{})
	dispatchStart([]byte(`{"abi":1,"config":{"servers":[{"id":"b","host":"laptop.local","port":3000,"websocket":true,"enabled":true}]}}`))

	b := c.ByID("b")
	if b.conn != RowRefused {
		t.Fatalf("a refused websocket reads %q", b.conn)
	}
	if b.retryTimer >= 0 {
		t.Fatal("a refusal every two seconds for ever is not a retry")
	}
	if got := status(t).Items[0].Detail; got != "websocket refused; the server is not on this boat's network" {
		t.Fatalf("the row says %q", got)
	}
}

func TestAConnectionWithNoAddressIsNotDialled(t *testing.T) {
	_, c := startServers(t, `{"servers":[{"id":"a","host":"","port":8375,"enabled":true}]}`)
	if len(testHost.Dialled) != 0 {
		t.Fatalf("nothing to dial: %v", testHost.Dialled)
	}
	if c.ByID("a").conn != RowNoAddress {
		t.Fatalf("the connection reads %q", c.ByID("a").conn)
	}
}

func TestAnEmptyListSaysSoRatherThanSayingNothing(t *testing.T) {
	_, _ = startServers(t, `{}`)
	s := status(t)
	if s.State != "degraded" || s.Detail != "no servers" {
		t.Fatalf("the status is %+v", s)
	}
}

func TestTheConnNoteFollowsTheRate(t *testing.T) {
	_, c := startServers(t, `{"servers":[{"id":"a","host":"10.0.0.2","port":8375,"enabled":true}]}`)
	a := c.ByID("a")
	dispatchEvent(TCPConnected, a.sock, nil)
	dispatchEvent(Timer, c.statusTimer, nil)
	if got := status(t).Items[0].Detail; got != "0 deltas/s, nothing parsed yet" {
		t.Fatalf("the row says %q", got)
	}
}

func TestTheListDeclaresTheSchemaTheManifestCarries(t *testing.T) {
	resetHost()
	c := newServers()
	got, err := SettingsJSON(&skPlugin{}, c)
	if err != nil {
		t.Fatal(err)
	}
	sameSchema(t, got, `{"groups":[{"label":"Signal K servers","tab":"connections","list":{
		"key":"servers","add_label":"Add Server",
		"discover":[{"service":"_signalk-ws._tcp","set":{"websocket":true}}],
		"switch_key":"enabled","item_fields":[
		{"key":"name","label":"Name","desc":"What you call this source. Leave it empty to show the address.","kind":"text","optional":true},
		{"key":"host","label":"Address","desc":"The name or IP address to connect to.","kind":"text","default":""},
		{"key":"port","label":"Port","desc":"Most Signal K servers stream on port 8375.","kind":"number","min":1,"max":65535,"default":8375},
		{"key":"websocket","label":"WebSocket","desc":"Read the WebSocket stream instead of the plain one.","kind":"toggle","default":false},
		{"key":"enabled","label":"On","desc":"Off closes the connection and stops reconnecting.","kind":"toggle","default":true}]}}]}`)
}

func TestAConnectionListWithNoOnDataIsRefused(t *testing.T) {
	resetHost()
	newServers()
	Register(&funcPlugin{draw: func(c *Chart) {}})
	if rc := dispatchStart([]byte(`{"abi":1,"config":{}}`)); rc == 0 {
		t.Fatal("a list with nothing to read the bytes must not start")
	}
	if len(logsWith("no OnData")) == 0 {
		t.Fatalf("the log must say why: %v", testHost.Logs)
	}
}
