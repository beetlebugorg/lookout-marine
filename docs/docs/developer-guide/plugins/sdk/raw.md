---
id: raw
title: The raw calls
---

# The raw calls

The SDK ships a set of low-level functions under `lk.raw`. They are ordinary
functions your plugin calls like any other, from the same import you already
have, and they are what the rest of the SDK is built on: HTTP, UDP,
websockets, storage, timers, the store. You reach for one when nothing on the
declared surface does the job, and using one gives nothing else up: your
inputs, your `draw` function and your connections keep working as before.

Most raw calls are requests, and the answer arrives in your `onEvent`
function; [Handling events](events.md) is that side of the story. Each call
returns -1 when your manifest did not ask for the capability it needs.

| Family | Calls |
|---|---|
| Storage | `storageGet`, `storagePut` |
| HTTP | `httpGet`, `httpFetch`, `HttpRequest`, `HttpResponse.header(name)` |
| UDP | `udpOpen`, `udpSend`, `udpClose` |
| WebSocket | `wsConnect(url, protocols)`, `wsSend`, `wsClose` |
| TCP | `tcpConnect`, `tcpSend`, `tcpClose` |
| Timers | `timerSet(ms, repeat)`, `timerCancel(id)` |
| Files | `fileRead`, `fileWrite`, and the `file_opened` event |
| The store, raw | `subscribePaths`, `aisSubscribe`, `readings(payload)`, `targets(payload)` |
| Publishing, raw | `Publish` and `AisUpsert` with a caller buffer and an explicit timestamp |
| The overlay, raw | `Overlay`: `symbol`, `polyline`, `polygon`, `del`, `send`, and the ownship-anchored and pick variants |
| Text | `logf`, `status`, `raiseAlert`, `Buf`, and the JSON helpers |

The answers are typed payloads: `TcpData`, `UdpData`, `WsOpen`, `WsData`,
`WsClosed`, `HttpResponse`, and `FileOpened`, whose `writable` field says
whether `fileWrite` will be honoured.

The doc comments in `plugins/common/lk.zig` are the reference for each call,
and [event kinds](../wire.md#event-kinds) is the wire reference for what each
payload carries and when it arrives.
