---
id: connections
title: Connecting to instruments
---

import Tabs from '@theme/Tabs';
import TabItem from '@theme/TabItem';

# Connecting to instruments

**Capabilities:** `net.tcp-client`, or `net.ws` with the hosts named, plus
`vessel.publish` and `ais.publish` for what you put in the stores.

A connection is a TCP or WebSocket link to an instrument on the network. The
mariner adds connections in the settings window and switches them on and off
there. Lookout opens each socket, reconnects when it drops, and shows its
status. The plugin parses what arrives.

One declaration gives the plugin the whole surface: the settings section the
mariner fills in, a socket per connection, the reconnect clock, the failure
count behind "unreachable", the pause switch, the per-connection status and
the plugin's own status line.

<Tabs groupId="plugin-language">
<TabItem value="zig" label="Zig" default>

```zig
const lk = @import("lk2");

comptime {
    lk.plugin(@This());
}

pub const Connections = lk.connections(.{
    .key = "servers",
    .group = "Signal K servers",
    .add_label = "Add Server",
    .status_empty = "no servers",
    .rate_noun = "delta",
    .Extra = struct {
        websocket: lk.Flag = .{
            .label = "WebSocket",
            .desc = "Connect with a websocket instead of a plain TCP stream.",
            .default = false,
        },
    },
    // Per-connection parse state: the partial line.
    .State = struct { partial: lk.Str(512) = .{} },
});

/// Bytes from one connection's socket.
pub fn onData(conn: *Connections.Connection, bytes: []const u8) void {
    conn.state.partial.append(bytes);
    conn.count(1);
}
```

</TabItem>
<TabItem value="go" label="Go">

```go
package main

import lk "github.com/beetlebugorg/lookout-marine/sdk/go/lookout"

// One connection: the plugin's extra columns, and the state its parser keeps.
type feed struct {
	WebSocket bool `lk:"websocket" label:"WebSocket" desc:"Connect with a websocket instead of a plain TCP stream." default:"false"`

	partial []byte
}

var servers = lk.Connections(lk.ConnOpts{
	Key:         "servers",
	Group:       "Signal K servers",
	AddLabel:    "Add Server",
	StatusEmpty: "no servers",
	RateNoun:    "delta",
	State:       func() any { return &feed{} },
})

type signalK struct{}

func init() { lk.Register(&signalK{}) }

func main() {}

// OnData is bytes from one connection's socket.
func (p *signalK) OnData(conn *lk.Conn, data []byte) {
	s := conn.State.(*feed)
	s.partial = append(s.partial, data...)
	conn.Count(1)
}
```

</TabItem>
<TabItem value="rust" label="Rust">

```rust
use lookout as lk;

lk::columns! {
    pub struct SkColumns {
        websocket: Flag {
            label: "WebSocket",
            desc: "Connect with a websocket instead of a plain TCP stream.",
            default: false,
        },
    }
}

struct Servers;

impl lk::ConnSpec for Servers {
    type Columns = SkColumns;       // beyond the four every list carries
    type State = Vec<u8>;           // per-connection parse state: the partial line
    const OPTS: lk::ConnOpts = lk::ConnOpts {
        key: "servers",
        group: "Signal K servers",
        add_label: "Add Server",
        status_empty: "no servers",
        rate_noun: "delta",
        ..lk::ConnOpts::DEFAULT
    };
}

#[derive(Default)]
struct SignalK;

lk::plugin!(SignalK, connections: Servers);

impl lk::Plugin for SignalK {
    // It publishes and draws nothing, so it asks for no draw timer.
    const DRAW_RATE_MS: i64 = 0;
}

impl lk::Source<Servers> for SignalK {
    /// Bytes from one connection's socket.
    fn on_data(&mut self, conn: &mut lk::Connection<Servers>, bytes: &[u8]) {
        conn.state.extend_from_slice(bytes);
        conn.count(1);
    }
}
```

</TabItem>
</Tabs>

Every connection has a name, an address, a port and an on switch, and Lookout
owns those fields. The `websocket` field above is the plugin's own, and so is
the parse state each connection keeps between reads.

## The declaration

```zig
pub const Connections = lk.connections(.{
    .key = "gateways",
    .group = "NMEA gateways",
    .footer = "Give the address of your instrument network's gateway.",
    .empty = "No gateways yet.",
    .add_label = "Add Gateway",
    .status_empty = "no gateways",
    .rate_noun = "msg",
    .columns = .{
        .port = .{
            .label = "Port",
            .desc = "Most WiFi gateways serve NMEA 0183 on port 10110.",
            .min = 1,
            .max = 65535,
            .default = 10110,
        },
    },
    .Extra = struct {
        websocket: lk.Flag = .{ .label = "WebSocket", .default = false },
    },
    .State = struct { line: lk.Str(96) = .{} },
});
```

| Option | Default | What it does |
|---|---|---|
| `key` | required | the config key the connection list arrives under |
| `group` | required | the section heading in the settings window |
| `tab` | `.connections` | which settings tab the group lands on |
| `footer`, `empty`, `add_label` | empty | the list's own wording in the settings window |
| `discover` | empty | the DNS-SD services a shell browses the boat's network for |
| `columns` | the SDK's wording | words the four standard fields and sets the port's range |
| `Extra` | `struct {}` | fields beyond the four, declared like a settings group |
| `State` | `struct {}` | per-connection state the plugin keeps: a framer, a parser, an identity |
| `reconnect_ms` | `2_000` | delay before a dropped connection is retried |
| `unreachable_after` | `3` | failed connects in a row before a connection reads as unreachable |
| `status_ms` | `2_000` | how often the status is rebuilt, and the window a rate is averaged over |
| `rate_noun` | `"msg"` | what `conn.count` counts, for the status: `42 msg/s` |
| `status_empty` | `"nothing configured"` | the plugin's detail when the mariner has added no connections |
| `no_answer_detail` | `"check the address"` | what a connection says once it reads as unreachable |
| `refused_detail` | `"the host refused this address"` | what a connection says when Lookout would not dial it |

The Zig SDK keeps its buffers fixed, so a connection list holds up to 8
connections, more than a boat's instrument network needs. Each connection is
matched to its socket by an id Lookout assigns, so editing one never disturbs
another's stream. Only an address change, a column change, a pause or a
delete closes a socket.

The extra columns are declared like settings fields: `lk.Flag` is a switch,
`lk.Num` a number with a range, `lk.Text` a text field. `lk.Text` carries
`label`, `desc`, `default` and `optional`; optional means no default.

## Being found without an address

A source that announces itself over DNS-SD can be added without the mariner
typing anything. Name the service types your list accepts, and a shell browses
for them while the settings window is open, offering each answer above the Add
button with the address it answered on.

<Tabs groupId="plugin-language">
<TabItem value="zig" label="Zig" default>

```zig
pub const Connections = lk.connections(.{
    .key = "servers",
    .group = "Signal K servers",
    .discover = &.{.{ .service = "_signalk-ws._tcp", .set = "{\"websocket\":true}" }},
    // …
});
```

</TabItem>
<TabItem value="go" label="Go">

```go
var servers = lk.Connections(lk.ConnOpts{
	Key:      "servers",
	Group:    "Signal K servers",
	Discover: []lk.Discover{{Service: "_signalk-ws._tcp", Set: `{"websocket":true}`}},
	// …
})
```

</TabItem>
<TabItem value="rust" label="Rust">

```rust
const OPTS: ConnOpts = ConnOpts {
    key: "servers",
    group: "Signal K servers",
    discover: &[Discover {
        service: "_signalk-ws._tcp",
        set: r#"{"websocket":true}"#,
    }],
    ..ConnOpts::DEFAULT
};
```

</TabItem>
</Tabs>

A row added from a find takes the service's name, host name and port. `set` is
a JSON object of the other columns it takes, and it is what makes a find
dialable when the address alone is not: a Signal K server announces its
websocket on port 3000, and a row that took that port with `websocket` off
would dial the web page. Every key must name a column of this list, and every
value must be that column's kind, or the manifest is refused.

THE HOST NAME IS WHAT IS KEPT, not the address behind it. A lease turns over
and the address changes; the name still reaches the same machine.

A list may name four service types at most. Only the Apple shells browse today,
and each shell also has to ship the type in its own platform declaration, so a
service type no shell knows is browsed for by nobody.

## The hooks

| Hook | When |
|---|---|
| `onData(conn, bytes)` | bytes from one connection's socket. Required |
| `onOpen(conn)` | a stream came up. Send a subscription here |
| `onClose(conn)` | a stream ended |
| `connectionNote(conn)` | a phrase to add after the connection's rate |
| `endpoint(conn)` | where to dial, when it is not the connection's host and port |

`endpoint` returns an `lk.Endpoint`:
`.{ .tcp = .{ .host = …, .port = … } }`, `.{ .ws = url }`, or
`.{ .refused = "why" }`. A refused connection stops retrying and shows that
sentence as its status.

```zig
pub fn endpoint(conn: *Connections.Connection) lk.Endpoint {
    if (!conn.cols.websocket) return .{ .tcp = .{ .host = conn.host.text(), .port = conn.port } };
    return .{ .ws = buildUrl(conn) };
}
```

## The connection object

Every hook receives the same connection object. Its fields are what the
mariner filled in plus your own columns and state; its methods talk to the
socket and the status line.

| Field | Type | What it is |
|---|---|---|
| `id` | `lk.Str(32)` | Lookout's id for the connection. It survives an edit |
| `name` | `lk.Str(48)` | what the mariner calls it. May be empty |
| `host` | `lk.Str(128)` | |
| `port` | `u16` | |
| `enabled` | `bool` | false means paused |
| `cols` | the `Extra` values | `f64`, `bool` or a fixed string per field |
| `state` | the `State` struct | the plugin's own, reset when the connection changes address |

`lk.Str(n)` is a fixed string: `.text()` reads it, `.set` and `.append`
write it and cut at the capacity, `.clear()` empties it, and `.full()` says
whether a write was cut.

| Call | What it does |
|---|---|
| `conn.label()` | the mariner's name, or the address |
| `conn.connected()` | true while the stream is up |
| `conn.send(bytes)` | write to this connection's stream |
| `conn.count(n)` | count `n` of whatever this connection carries, for the rate |
| `conn.setDetail(fmt, args)` | add a phrase to this connection's status line |
| `Connections.all()` | every connection the mariner has, in the order the settings window shows |
| `Connections.byId(id)` | one connection, or null |

Lookout posts the plugin's status line and one status item per connection:
`connected`, `reconnecting`, `unreachable`, `paused`, `no_address` or
`refused`. The plugin's own line counts what is up:
`2 of 3 connected, 44 msg/s`. `conn.count` is what feeds the rate.

Reference: [lists](../wire.md#lists-a-group-the-mariner-adds-rows-to) and
[status items](../wire.md#status-items-one-line-per-row).
