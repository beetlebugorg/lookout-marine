"""Rasterize lookout-beacon.svg at a given size.

The mark carries <text> soundings set in the system UI face, so the rasterizer
has to do real text layout with a real font. ImageMagick's internal SVG reader
cannot ("unable to read font"), and rsvg-convert/resvg/inkscape are not
installed here. macOS QuickLook renders SVG through WebKit, which does, and
ships with the OS — so qlmanage is the rasterizer.

QuickLook fits the SVG into a fixed reference box of roughly 298pt before
scaling it into the requested thumbnail, so an SVG that declares its intrinsic
size as 128 fills only ~43% of the output and the rest is padding. Declaring a
size at or above that reference makes the artwork fill the thumbnail exactly;
a temporary copy declaring 1024 is what actually gets rendered, at whatever
pixel size -s asks for.
"""

# Any value at or above QuickLook's ~298pt reference box gives a 100% fill.
DECLARED = 1024
import re
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image


def render(svg_path: Path, size: int, out_path: Path) -> None:
    src = svg_path.read_text()
    scaled, n = re.subn(
        r'width="\d+(?:\.\d+)?" height="\d+(?:\.\d+)?"',
        f'width="{DECLARED}" height="{DECLARED}"',
        src,
        count=1,
    )
    if n != 1:
        raise SystemExit(f"{svg_path}: no intrinsic width/height to override")

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        stage = tmp / f"render-{size}.svg"
        stage.write_text(scaled)
        subprocess.run(
            ["qlmanage", "-t", "-s", str(size), "-o", str(tmp), str(stage)],
            check=True, capture_output=True,
        )
        produced = tmp / f"{stage.name}.png"
        if not produced.exists():
            raise SystemExit(f"qlmanage produced nothing for {size}px")
        im = Image.open(produced).convert("RGBA")

    if im.size != (size, size):
        raise SystemExit(f"qlmanage returned {im.size}, expected {size}x{size}")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    im.save(out_path)


if __name__ == "__main__":
    svg = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    for size in (int(a) for a in sys.argv[3:]):
        target = out_dir / f"beacon-{size}.png"
        render(svg, size, target)
        print(f"  {target.name}")
