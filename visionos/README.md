# Lookout Table (visionOS)

The chart as a sheet of paper lying on a real table.

The mariner places a volume where a chart table would be, and a paper chart
lies in it: white margin, printed face, a shadow on the table under it. The
chart is the same engine every other Lookout shell draws with. What a headset
adds is the third dimension, so traffic stands off the paper as little hulls
with flags over them, and a tap floats what the chart says about a spot above
that spot.

## The one rule

**The margin is the object. The face is the map.**

| A hand on | Does |
|---|---|
| the white margin, dragging | moves the sheet in the room |
| the white margin, two hands apart | resizes the sheet, showing more chart at the same scale |
| the white margin, two hands turning | turns the sheet on the table |
| the printed chart, dragging | pans the chart, and a throw coasts |
| the printed chart, two hands apart | zooms the chart |
| the printed chart, two hands turning | turns the chart under the paper |
| the printed chart, tapping | floats what the chart holds there over the spot |

It is what a paper chart already teaches: you slide the sheet by its edge and
you read the chart inside it. Looking at the margin lights it, which is the only
hint the app gives.

Four buttons sit under the volume: day/dusk/night, fit the whole chart, center
own ship, and square the sheet back up.

## Building

```
brew install xcodegen              # once
visionos/build.sh                  # simulator, Debug
visionos/build.sh device Release   # a Vision Pro
```

`build.sh` generates the Xcode project from `project.yml`, cross-builds the zig
cores for the platform, builds the WAMR plugin runtime and the image codecs if
they are not already built, and links the app. The products land in
`visionos/build-xros/Build/Products/`.

Everything the app needs is in this repository plus Xcode and Zig. The first
build takes a few minutes for WAMR, libpng and libwebp; after that it is
incremental.

## Charts

The app looks for baked `.pmtiles` charts in this order:

1. `$LOOKOUT_CHARTS`, a file or a directory (a development convenience).
2. The app's own Documents folder, which the Files app shows and a mariner can
   copy charts into.
3. The sample cell in the bundle, so a fresh install draws something.

A directory is walked for every `.pmtiles` under it, however many that is. A
whole ENC_ROOT is thousands of cells; tile57 memory-maps them rather than
holding them resident, which is what makes that affordable.

## Traffic

Own ship, AIS, NMEA 0183, Signal K and laylines are wasm plugins and travel in
the bundle. Traffic appears when a plugin is fed. For development, serve the
recorded log to the plugin's TCP connection:

```
zig run tools/nmea_gen.zig -- test/annapolis.nmea      # once
zig run -lc tools/nmea_replay.zig -- --port 10110
```

The simulator reaches that at 127.0.0.1. A device needs the machine's address
on the network, and this app has no settings UI to change it yet.

## Testing

The visionOS simulator does not run on every machine: its system shell renders
with RealityKit and crash-loops on a paravirtualized GPU. So the parts that can
be run away from a headset are run on the Mac:

```
visionos/tests/run.sh
```

It exercises the RealityKit drawable queue with the app's own descriptor, the
core's texture render path, the present callback, real chart pixels, the
geo-to-sheet mapping in both directions, the pan direction, the cost of a frame,
and the AIS decoder the app ships, against the live plugin table when a feed is
running and against the ABI's documented example when it is not.

The renderer's own texture path has a test in charttable
(`metal texture path: a host-owned target draws, and a bad one is refused`).
