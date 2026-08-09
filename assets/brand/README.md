# Lookout Marine — brand mark

Two marks, same chart: `lookout-beacon` (full crop) and `lookout-beacon-quiet` (reduced).
Everything is drawn on the S-52 palette already in the app — no new colours.

## Files

- `lookout-beacon.svg` — master, 128×128 viewBox, scales to anything. Use this on the docs site.
- `lookout-beacon-quiet.svg` — the reduced mark.
- `*-mono.svg` — single-colour versions. They paint with `currentColor`: set `color` on the
  parent, or `fill`/`stroke` on the `<svg>`. Use for favicons, print, and the macOS menu-bar/template icon.
- `png/<name>-<size>.png` — 16 · 32 · 48 · 64 · 128 · 256 · 512 · 1024, full-bleed square.
- `png/beacon-macos-1024.png` — macOS master: artwork inset and squircle-masked per Apple's grid.

## Per platform

**macOS** — `iconutil` wants an iconset built from `beacon-macos-1024.png`:

```sh
mkdir LookoutMarine.iconset
sips -z 16 16   png/beacon-macos-1024.png --out LookoutMarine.iconset/icon_16x16.png
sips -z 32 32   png/beacon-macos-1024.png --out LookoutMarine.iconset/icon_16x16@2x.png
sips -z 32 32   png/beacon-macos-1024.png --out LookoutMarine.iconset/icon_32x32.png
sips -z 64 64   png/beacon-macos-1024.png --out LookoutMarine.iconset/icon_32x32@2x.png
sips -z 128 128 png/beacon-macos-1024.png --out LookoutMarine.iconset/icon_128x128.png
sips -z 256 256 png/beacon-macos-1024.png --out LookoutMarine.iconset/icon_128x128@2x.png
sips -z 256 256 png/beacon-macos-1024.png --out LookoutMarine.iconset/icon_256x256.png
sips -z 512 512 png/beacon-macos-1024.png --out LookoutMarine.iconset/icon_256x256@2x.png
sips -z 512 512 png/beacon-macos-1024.png --out LookoutMarine.iconset/icon_512x512.png
cp              png/beacon-macos-1024.png     LookoutMarine.iconset/icon_512x512@2x.png
iconutil -c icns LookoutMarine.iconset
```

Drop the `.icns` in `macos/LookoutMarine/Assets.xcassets/AppIcon.appiconset/` (or drag the 1024 into
the AppIcon slot in Xcode and let it generate the rest).

**iOS / iPadOS** — one 1024 square, no rounding, no alpha: `png/beacon-1024.png` into the
AppIcon single-size slot. iOS applies the mask.

**Windows** — a multi-resolution `.ico`:

```sh
magick png/beacon-16.png png/beacon-32.png png/beacon-48.png png/beacon-64.png \
       png/beacon-128.png png/beacon-256.png LookoutMarine.ico
```

Reference it from the WinUI 3 app manifest (`Package.appxmanifest` → `Logo`) and from the
`ApplicationIcon` property in the .csproj.

**Linux** — install the PNGs into the hicolor theme and ship the SVG as scalable:

```
/usr/share/icons/hicolor/<size>x<size>/apps/org.beetlebug.LookoutMarine.png
/usr/share/icons/hicolor/scalable/apps/org.beetlebug.LookoutMarine.svg
```

Name the icon in the .desktop file and in `gtk_window_set_default_icon_name()`.

**Android** — `png/beacon-1024.png` as the foreground layer of an adaptive icon; the design is
full-bleed, so it survives every mask. Set the background layer to `#c9edff` (DEPDW) if the
launcher needs a separate one.

**Web / docs** — `lookout-beacon.svg` for the site, `lookout-beacon-mono.svg` for the favicon:

```html
<link rel="icon" href="/lookout-beacon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="/beacon-256.png">
```

## Wordmark

There is no drawn wordmark. Set **Lookout Marine** in the platform UI face at semibold, as the
startup loader already does, with the mark at the cap-height of the text and one space of clearance.

_Not for navigation._

---

## What this repo ships

Everything above is the brand pack's own text. The notes below are this repo's.

The app icon on every platform is **`lookout-beacon.svg` — the full beacon chart crop, design
option 2a, with the sector lights off**. The SVG's own comment records the design source it came
from. The quiet mark is kept here as a master but no platform icon is built from it.

This directory holds the masters and the two scripts that turn them into platform artifacts.
Nothing per-size is kept here: every generated size lands in the platform's own directory —
`macos/…/Assets.xcassets`, `windows/`, `linux/data/`, `android/…/res`.

| file | what it feeds |
| --- | --- |
| `lookout-beacon.svg` | every platform icon; the Linux scalable hicolor icon; the docs site |
| `lookout-beacon-mono.svg` | single-colour uses — favicons, print, menu-bar templates |
| `lookout-beacon-quiet.svg`, `lookout-beacon-quiet-mono.svg` | the reduced mark |
| `beacon-1024.png` | iOS, Windows, Linux and Android icons |
| `beacon-macos-1024.png` | the macOS iconset |

Both PNGs are generated from `lookout-beacon.svg` and are regenerable; they are kept here because
they are what the per-platform recipes take as input, and because the macOS one carries a mask
that is not in the SVG.

### Rasterizing the SVG

`rasterize.py` renders the mark at any size. Two things force the choice of rasterizer:

- The mark sets its soundings as `<text>` in the system UI face, so the rasterizer has to do real
  text layout with a real font. ImageMagick's built-in SVG reader cannot — it fails with
  "unable to read font" — and rsvg-convert, resvg and inkscape are not part of a stock macOS.
- macOS QuickLook renders SVG through WebKit, which does, and ships with the OS.

So `qlmanage` is the rasterizer. One quirk it hides: QuickLook fits the SVG into a reference box
of about 298pt before scaling it into the requested thumbnail, so a mark declaring the pack's
intrinsic `width="128"` fills only ~43% of the output and the rest comes out as padding. The
script renders a temporary copy that declares 1024 instead, which pins the fill at 100% for every
requested size.

```sh
python3 rasterize.py lookout-beacon.svg <out-dir> 16 32 48 64 128 256 512 1024
```

`mkico.py` packs a rendered ladder into the Windows `.ico`. It is here rather than the `magick`
one-liner above because magick writes every frame as an uncompressed DIB, which makes the 256
frame alone ~262 KB; this one stores that frame as PNG and the rest as DIBs.

```sh
python3 mkico.py <ladder-dir> ../../windows/LookoutMarine.ico
```

### beacon-macos-1024.png is derived

The pack ships no squircle-masked master for this artwork, so it is built here by measuring the
one the pack did ship and applying the same treatment:

- **Inset** — the full-bleed square is rendered at 824×824 and centred at (100,100). That is
  Apple's macOS grid and it measures exactly: the reference master's opaque bounding box is
  `(100, 100, 924, 924)`.
- **Background** — none. Inside the squircle the pixels are the artwork itself; the mark is
  full-bleed and needs no ground behind it. Confirmed by differencing the reference master's inner
  824 square against the same artwork scaled to 824: mean absolute difference below 0.5/255, the
  residual being edge antialiasing from a different resampler.
- **Mask** — the alpha channel of the pack's macOS master, reused verbatim rather than
  reconstructed. The mask is artwork-independent, so the two silhouettes come out byte-identical.

```sh
python3 rasterize.py lookout-beacon.svg /tmp/mac 824
python3 - <<'PY'
from PIL import Image
art  = Image.open('/tmp/mac/beacon-824.png').convert('RGB')
mask = Image.open('<pack>/png/beacon-macos-1024.png').convert('RGBA').getchannel('A')
out = Image.new('RGB', (1024, 1024)); out.paste(art, (100, 100))
out = out.convert('RGBA'); out.putalpha(mask)
out.save('beacon-macos-1024.png')
PY
```
