---
id: settings
title: Adding settings
---

# Adding settings

**Capabilities:** none. A setting is declared, not granted.

A settings group is a struct. Each field carries its label, range and default
as its own default value, and the same declaration renders the manifest's
schema, so a range cannot drift from the code that clamps against it.

```zig
pub const Settings = struct {
    pub const group = "Downwind line";
    pub const tab: lk.Tab = .display;

    length_nm: lk.Num = .{
        .label = "Line length",
        .desc = "How far downwind the line reaches.",
        .unit = "nm",
        .min = 0.1,
        .max = 10,
        .default = 1,
    },
    dashed: lk.Flag = .{
        .label = "Dashed",
        .desc = "Draw the line broken, so it does not read as something charted.",
        .default = true,
    },
};

pub fn draw(c: *lk.Chart) void {
    const s = lk.settings(Settings);
    const from = inputs.boat.get();
    c.line("windline", &.{ from, from.destination(180, lk.nm(s.length_nm)) }, .{
        .color = .warning,
        .dash = s.dashed,
    });
}
```

`lk.settings(Settings)` is a plain struct of the values in force: `f64` for
an `lk.Num`, `bool` for an `lk.Flag`. A number outside its range is clamped
before it arrives, and a value of the wrong type is refused rather than
coerced.

| Declaration | The mariner sees | The plugin reads |
|---|---|---|
| `lk.Num` | a number field with its unit beside it | `f64`, clamped into `min`–`max` |
| `lk.Flag` | a switch | `bool` |
| `lk.Text` | a text field | a fixed string; legal only as a connection column |
| `pub const group` | the heading above the fields | |
| `pub const tab` | which settings tab it lands on | |

The tabs are `display`, `depths`, `text`, `charts`, `vessels`, `alarms`,
`connections` and `advanced`. A group with no `tab` lands on `advanced`.
Lookout files your group under that tab beside its own settings and does not
say which plugin added it.

For more than one group, declare `pub const Settings = .{ Alarm, Display };`
and read each with `lk.settings(Alarm)`. One plugin declares at most 16
fields, counting every group and every connection column.

There is no scalar text setting. `lk.Text` outside a connection column is a
compile error, because Lookout keeps no scalar string.

Declare `pub fn onSettings() void` to recompute something after a change. You
do not need it to redraw: Lookout re-reads the values and calls your `draw`
function again the moment the mariner changes one.

## Checking the manifest against the struct

The manifest is verified rather than generated. Put the settings in a file
that imports only the SDK and test it:

```zig
test "the manifest ships the schema this file declares" {
    try lk.expectManifest(@embedFile("manifest.json"), .{Settings});
}
```

The test parses both sides, so key order and whitespace do not matter. When
they differ it prints the JSON to paste into the manifest.
`lk.settingsJson(.{Settings})` returns the same text on its own.
`plugins/signalk/config.zig` does this for a connection list.

Reference: [the settings schema](../wire.md#settings-schema-v2).
