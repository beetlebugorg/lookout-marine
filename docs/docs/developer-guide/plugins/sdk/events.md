---
id: events
title: Handling events
---

import Tabs from '@theme/Tabs';
import TabItem from '@theme/TabItem';

# Handling events

A [raw call](raw.md) is a request, and `onEvent` is where the answer
arrives.
`lk.raw.httpGet` asks for a page, `lk.raw.timerSet` asks for a tick,
`lk.raw.subscribePaths` asks for store changes: the response to each lands in
your `onEvent` function. A file the mariner opens with your plugin arrives
there too.

Your declared surface never does. Inputs, the draw timer, settings and
connections handle their own events, so a plugin that makes no raw calls and
claims no file types never hears `onEvent` fire.

<Tabs groupId="plugin-language">
<TabItem value="zig" label="Zig" default>

```zig
const lk = @import("lk2");

comptime {
    lk.plugin(@This());
}

/// Every event the SDK did not consume.
pub fn onEvent(e: lk.raw.Event) !void {
    switch (e) {
        .http_response => |r| lk.log(.info, "{d}, {d} bytes", .{ r.status, r.body.len }),
        else => {},
    }
}
```

</TabItem>
<TabItem value="go" label="Go">

```go
package main

import lk "github.com/beetlebugorg/lookout-marine/sdk/go/lookout"

type probe struct{}

func init() { lk.Register(&probe{}) }

func main() {}

// OnEvent is every event the SDK did not consume.
func (p *probe) OnEvent(e lk.Event) error {
	if e.Kind == lk.HTTPResponded {
		r := e.Response()
		lk.Log(lk.Info, "%d, %d bytes", r.Status, len(r.Body))
	}
	return nil
}
```

</TabItem>
<TabItem value="rust" label="Rust">

```rust
use lookout as lk;

#[derive(Default)]
struct Probe;

lk::plugin!(Probe);

impl lk::Plugin for Probe {
    /// Every event the SDK did not consume.
    fn on_event(&mut self, e: &lk::raw::Event<'_>) -> lk::Result {
        if let lk::raw::Event::HttpResponse(r) = e {
            lk::log!(lk::Level::Info, "{}, {} bytes", r.status, r.body.len());
        }
        Ok(())
    }
}
```

</TabItem>
</Tabs>
