#!/usr/bin/env python3
"""Validate bundled PNGs without loading Factorio or modifying image pixels."""
from pathlib import Path
import re
import struct
import zlib

ROOT = Path(__file__).resolve().parent.parent


def png_rows(path):
    content = path.read_bytes()
    assert content[:8] == b"\x89PNG\r\n\x1a\n", f"Invalid PNG: {path}"
    offset, compressed = 8, bytearray()
    while offset < len(content):
        size = struct.unpack_from(">I", content, offset)[0]
        kind = content[offset + 4:offset + 8]
        payload = content[offset + 8:offset + 8 + size]
        expected_crc = struct.unpack_from(">I", content, offset + 8 + size)[0]
        assert zlib.crc32(kind + payload) == expected_crc, f"Corrupt PNG chunk in {path}"
        if kind == b"IHDR":
            width, height, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", payload)
            assert (depth, color, compression, filtering, interlace) == (8, 6, 0, 0, 0), "Expected non-interlaced RGBA8"
        elif kind == b"IDAT":
            compressed.extend(payload)
        offset += size + 12
    raw = zlib.decompress(compressed)
    stride = width * 4
    assert len(raw) == height * (stride + 1)
    rows, previous = [], bytearray(stride)
    for y in range(height):
        start = y * (stride + 1)
        mode = raw[start]
        assert mode <= 4
        row = bytearray(raw[start + 1:start + 1 + stride])
        for x in range(stride):
            left = row[x - 4] if x >= 4 else 0
            above = previous[x]
            corner = previous[x - 4] if x >= 4 else 0
            if mode == 1:
                predictor = left
            elif mode == 2:
                predictor = above
            elif mode == 3:
                predictor = (left + above) // 2
            elif mode == 4:
                p = left + above - corner
                a, b, c = abs(p - left), abs(p - above), abs(p - corner)
                predictor = left if a <= b and a <= c else above if b <= c else corner
            else:
                predictor = 0
            row[x] = (row[x] + predictor) % 256
        rows.append(row)
        previous = row
    return width, height, rows


def main():
    references = set()
    for path in (ROOT / "prototypes").glob("*.lua"):
        references.update(re.findall(r'__tank-squads__/([^"\s]+\.png)', path.read_text()))
    # Insignia and rank sprites are named in data modules, not literal paths.
    for folder in ("graphics/insignias", "graphics/veteran-status"):
        references.update(str(p.relative_to(ROOT)) for p in (ROOT / folder).glob("*.png"))
    assert references, "No bundled graphics referenced"
    for relative in sorted(references):
        path = ROOT / relative
        assert path.is_file(), f"Missing bundled asset: {relative}"
        width, height, rows = png_rows(path)
        alpha = [row[3::4] for row in rows]
        clear = sum(row.count(0) for row in alpha)
        solid = sum(sum(value >= 240 for value in row) for row in alpha)
        assert clear > width * height * 0.1, f"Opaque background in {relative}"
        assert solid > width * height * 0.1, f"Missing opaque artwork in {relative}"
        if path.name == "barracks.png":
            assert (width, height) == (1536, 1024), "Atlas no longer matches prototype cells"
            for cell in range(8):
                x, y = (cell % 4) * 384, (cell // 4) * 512
                count = sum(row[x:x + 384].count(0) for row in alpha[y:y + 512])
                assert count > 384 * 512 * 0.1, f"Frame {cell} lacks transparency"
        elif path.name in {"chaingun-chassis.png", "siege-chassis.png", "flame-chassis.png", "headquarters-chassis.png"}:
            assert (width, height) == (1254, 1254), "Chassis atlas size differs from prototype"
            for cell in range(16):
                x, y = (cell % 4) * 313, (cell // 4) * 313
                clear_pixels = sum(row[x:x + 313].count(0) for row in alpha[y:y + 313])
                assert 313 * 313 * 0.1 < clear_pixels < 313 * 313 * 0.9, f"Invalid chassis direction {cell}"
        elif path.name == "siege-gun.png":
            assert (width, height) == (1254, 1254), "Recoil atlas differs from prototype"
            for cell in range(4):
                x, y = (cell % 2) * 627, (cell // 2) * 627
                count = sum(row[x:x + 627].count(0) for row in alpha[y:y + 627])
                assert 627 * 627 * 0.1 < count < 627 * 627 * 0.9, f"Invalid recoil frame {cell}"
        elif path.parent.name in {"insignias", "veteran-status"}:
            assert (width, height) == (512, 512), "Badge size differs from prototypes/insignias.lua"
        else:
            assert (width, height) == (1254, 1254), "Icon size differs from prototype"
        print(f"PASS {relative}: {width}x{height}, {clear} transparent pixels")


if __name__ == "__main__":
    main()
