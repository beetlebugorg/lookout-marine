# The plugins, and the SDK they import

`plugins/common/` is the SDK. Each other directory is a plugin that imports it
and is built to wasm by `zig build plugins`.

## What must stay true

- **A plugin's overlay is retained and diffed.** A plugin describes its whole
  scene every call; anything it does not draw is removed. There is no delete.
- **A capability check is per call.** A call the manifest did not ask for
  returns -1 and is counted as denied. It never traps.
- **The wire is frozen where it says so.** The `lk_abi` export name and the
  `{"abi":N}` start payload keep their old spelling on purpose; the manifest
  key is `api`.
- **An identity a fixture invents uses MID 899**, which is unallocated, so no
  real vessel can hold it; an aid uses 99 then 899 then four digits. An
  identity quoted from a published reference keeps its real value and carries
  a comment naming the source. See `plugins/nmea0183/fixtures.zig`.

- **A plugin decides on data and draws what it decided.** State a plugin keeps
  across calls is advanced in `onUpdate`, where the data lands. `draw` reads
  that state and renders it.
- **Nothing wakes without something to do.** A plugin is called when data
  arrives, and on a one-shot appointment armed for the exact moment one of its
  declared inputs stops counting. When nothing can expire, nothing is armed.

## The trap that keeps returning

`zig build` alone does NOT rebuild plugin wasm; `zig build plugins` does, and
it does not refresh the `org.example.*` modules in `zig-out/plugins` at all.
Stale wasm has sent this project chasing a phantom bug more than once, most
recently when three example plugins appeared not to have a change that was in
fact never compiled into them.
