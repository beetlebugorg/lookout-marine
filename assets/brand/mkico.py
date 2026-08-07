"""Compose a multi-resolution Windows .ico.

magick writes every frame as an uncompressed DIB, which makes the 256 frame
alone ~262 KB. Windows Vista and later read PNG-compressed frames, so the 256
goes in as a PNG and the smaller frames stay DIBs (what every shell reads
fastest). The container format is a 6-byte header, one 16-byte directory entry
per image, then the image data.
"""
import struct
import sys
from io import BytesIO

from PIL import Image


def dib_frame(im: Image.Image) -> bytes:
    """A 32-bit bottom-up BITMAPINFOHEADER DIB with the AND mask ICO wants."""
    w, h = im.size
    px = im.load()
    rows = []
    for y in range(h - 1, -1, -1):          # bottom-up
        row = bytearray()
        for x in range(w):
            r, g, b, a = px[x, y]
            row += bytes((b, g, r, a))      # BGRA
        rows.append(bytes(row))
    xor = b"".join(rows)

    # The AND mask: 1bpp, rows padded to 4 bytes. Fully opaque here, but the
    # field is not optional and biHeight counts both planes.
    mask_stride = ((w + 31) // 32) * 4
    and_mask = b"\x00" * (mask_stride * h)

    header = struct.pack(
        "<IiiHHIIiiII",
        40,          # biSize
        w, h * 2,    # biWidth, biHeight (XOR + AND stacked)
        1, 32,       # biPlanes, biBitCount
        0,           # biCompression = BI_RGB
        len(xor) + len(and_mask),
        0, 0, 0, 0,
    )
    return header + xor + and_mask


def png_frame(im: Image.Image) -> bytes:
    buf = BytesIO()
    im.save(buf, format="PNG", optimize=True)
    return buf.getvalue()


def build(out_path: str, sources: dict[int, str], png_at_or_above: int = 256) -> None:
    frames = []
    for size in sorted(sources):
        im = Image.open(sources[size]).convert("RGBA")
        if im.size != (size, size):
            raise SystemExit(f"{sources[size]} is {im.size}, expected {size}x{size}")
        data = png_frame(im) if size >= png_at_or_above else dib_frame(im)
        frames.append((size, data))

    offset = 6 + 16 * len(frames)
    directory = b""
    for size, data in frames:
        directory += struct.pack(
            "<BBBBHHII",
            size if size < 256 else 0,   # 0 means 256
            size if size < 256 else 0,
            0,      # palette count
            0,      # reserved
            1,      # colour planes
            32,     # bits per pixel
            len(data),
            offset,
        )
        offset += len(data)

    with open(out_path, "wb") as f:
        f.write(struct.pack("<HHH", 0, 1, len(frames)))  # reserved, type=icon, count
        f.write(directory)
        for _, data in frames:
            f.write(data)


if __name__ == "__main__":
    pack, out = sys.argv[1], sys.argv[2]
    build(out, {n: f"{pack}/beacon-quiet-{n}.png" for n in (16, 32, 48, 64, 128, 256)})
    print("wrote", out)
