#!/usr/bin/env python3
"""Verify that a macOS app icon has transparent corners and complete ICNS sizes."""

import argparse
import binascii
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path
from typing import List, Optional, Tuple

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
REQUIRED_ICNS_REPRESENTATIONS = {
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
}
OUTER_CORNER_SAMPLE = 64


class VerificationError(Exception):
    """Raised when an icon fails verification."""


def parse_png(path: Path, *, decode_pixels: bool) -> Tuple[int, int, Optional[List[bytes]]]:
    try:
        data = path.read_bytes()
    except OSError as error:
        raise VerificationError(f"cannot read PNG {path}: {error}") from error

    if not data.startswith(PNG_SIGNATURE):
        raise VerificationError(f"{path}: invalid PNG signature")

    offset = len(PNG_SIGNATURE)
    ihdr = None
    idat = bytearray()
    saw_iend = False
    while offset < len(data):
        if len(data) - offset < 12:
            raise VerificationError(f"{path}: truncated PNG chunk")
        length = struct.unpack_from(">I", data, offset)[0]
        chunk_end = offset + 12 + length
        if chunk_end > len(data):
            raise VerificationError(f"{path}: truncated PNG chunk data")
        chunk_type = data[offset + 4 : offset + 8]
        chunk_data = data[offset + 8 : offset + 8 + length]
        expected_crc = struct.unpack_from(">I", data, offset + 8 + length)[0]
        actual_crc = binascii.crc32(chunk_type + chunk_data) & 0xFFFFFFFF
        if expected_crc != actual_crc:
            raise VerificationError(f"{path}: invalid PNG chunk CRC")
        if chunk_type == b"IHDR":
            if ihdr is not None or length != 13:
                raise VerificationError(f"{path}: malformed PNG IHDR")
            ihdr = chunk_data
        elif chunk_type == b"IDAT":
            idat.extend(chunk_data)
        elif chunk_type == b"IEND":
            if length != 0:
                raise VerificationError(f"{path}: malformed PNG IEND")
            saw_iend = True
            offset = chunk_end
            break
        offset = chunk_end

    if ihdr is None:
        raise VerificationError(f"{path}: missing PNG IHDR")
    if not saw_iend:
        raise VerificationError(f"{path}: missing PNG IEND")
    if offset != len(data):
        raise VerificationError(f"{path}: unexpected data after PNG IEND")

    width, height, bit_depth, color_type, compression, filtering, interlace = struct.unpack(
        ">IIBBBBB", ihdr
    )
    if not decode_pixels:
        return width, height, None
    if bit_depth != 8 or color_type != 6:
        raise VerificationError(
            f"{path}: master PNG must be 8-bit RGBA with transparent outer corners; "
            f"got bit depth {bit_depth}, color type {color_type}"
        )
    if compression != 0 or filtering != 0:
        raise VerificationError(f"{path}: unsupported PNG compression or filter method")
    if interlace != 0:
        raise VerificationError(f"{path}: interlaced PNG is unsupported")
    if not idat:
        raise VerificationError(f"{path}: missing PNG IDAT data")

    try:
        filtered = zlib.decompress(bytes(idat))
    except zlib.error as error:
        raise VerificationError(f"{path}: invalid compressed PNG data: {error}") from error

    stride = width * 4
    expected_length = height * (stride + 1)
    if len(filtered) != expected_length:
        raise VerificationError(
            f"{path}: malformed PNG image data (expected {expected_length} bytes, got {len(filtered)})"
        )

    rows = []
    previous = bytearray(stride)
    cursor = 0
    for _ in range(height):
        filter_type = filtered[cursor]
        cursor += 1
        scanline = filtered[cursor : cursor + stride]
        cursor += stride
        row = unfilter_scanline(filter_type, scanline, previous, bytes_per_pixel=4, path=path)
        rows.append(bytes(row))
        previous = row
    return width, height, rows


def unfilter_scanline(
    filter_type: int,
    scanline: bytes,
    previous: bytearray,
    *,
    bytes_per_pixel: int,
    path: Path,
) -> bytearray:
    row = bytearray(len(scanline))
    for index, value in enumerate(scanline):
        left = row[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
        above = previous[index]
        upper_left = previous[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
        if filter_type == 0:
            predictor = 0
        elif filter_type == 1:
            predictor = left
        elif filter_type == 2:
            predictor = above
        elif filter_type == 3:
            predictor = (left + above) // 2
        elif filter_type == 4:
            predictor = paeth(left, above, upper_left)
        else:
            raise VerificationError(f"{path}: unsupported PNG filter type {filter_type}")
        row[index] = (value + predictor) & 0xFF
    return row


def paeth(left: int, above: int, upper_left: int) -> int:
    estimate = left + above - upper_left
    left_distance = abs(estimate - left)
    above_distance = abs(estimate - above)
    upper_left_distance = abs(estimate - upper_left)
    if left_distance <= above_distance and left_distance <= upper_left_distance:
        return left
    if above_distance <= upper_left_distance:
        return above
    return upper_left


def alpha_at(rows: List[bytes], x: int, y: int) -> int:
    return rows[y][x * 4 + 3]


def verify_master(path: Path) -> None:
    width, height, rows = parse_png(path, decode_pixels=True)
    assert rows is not None
    if (width, height) != (1024, 1024):
        raise VerificationError(f"{path}: master PNG must be 1024x1024, got {width}x{height}")

    corners = ((0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1))
    if any(alpha_at(rows, x, y) != 0 for x, y in corners):
        raise VerificationError(f"{path}: master PNG must have transparent outer corners")

    regions = (
        (range(OUTER_CORNER_SAMPLE), range(OUTER_CORNER_SAMPLE)),
        (range(width - OUTER_CORNER_SAMPLE, width), range(OUTER_CORNER_SAMPLE)),
        (range(OUTER_CORNER_SAMPLE), range(height - OUTER_CORNER_SAMPLE, height)),
        (
            range(width - OUTER_CORNER_SAMPLE, width),
            range(height - OUTER_CORNER_SAMPLE, height),
        ),
    )
    for xs, ys in regions:
        if any(alpha_at(rows, x, y) != 0 for y in ys for x in xs):
            raise VerificationError(
                f"{path}: sampled transparent outer corners contain non-transparent pixels"
            )

    if alpha_at(rows, width // 2, height // 2) == 0:
        raise VerificationError(f"{path}: master PNG center must be non-transparent")


def expected_iconset_from_master(master: Path, temporary: Path) -> Path:
    source_iconset = temporary / "expected-source.iconset"
    expected_icns = temporary / "expected.icns"
    expected_iconset = temporary / "expected.iconset"
    source_iconset.mkdir()
    for name, size in REQUIRED_ICNS_REPRESENTATIONS.items():
        output = source_iconset / name
        result = subprocess.run(
            ["sips", "-z", str(size), str(size), str(master), "--out", str(output)],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            diagnostic = result.stderr.strip() or result.stdout.strip() or "unknown sips error"
            raise VerificationError(f"{master}: sips scaling failed for {name}: {diagnostic}")
    result = subprocess.run(
        ["iconutil", "-c", "icns", str(source_iconset), "-o", str(expected_icns)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        diagnostic = result.stderr.strip() or result.stdout.strip() or "unknown iconutil error"
        raise VerificationError(f"{master}: iconutil packaging failed: {diagnostic}")
    result = subprocess.run(
        ["iconutil", "-c", "iconset", str(expected_icns), "-o", str(expected_iconset)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        diagnostic = result.stderr.strip() or result.stdout.strip() or "unknown iconutil error"
        raise VerificationError(f"{master}: iconutil extraction failed: {diagnostic}")
    return expected_iconset


def compare_icns_representation(
    icns: Path,
    representation: Path,
    expected: Path,
    name: str,
) -> None:
    expected_width, expected_height, expected_rows = parse_png(expected, decode_pixels=True)
    actual_width, actual_height, actual_rows = parse_png(representation, decode_pixels=True)
    if (actual_width, actual_height) != (expected_width, expected_height) or actual_rows != expected_rows:
        raise VerificationError(
            f"{icns}: ICNS representation {name} does not match master scaled with sips"
        )


def verify_icns(path: Path, master: Path) -> None:
    if shutil.which("iconutil") is None:
        raise VerificationError("iconutil is required to verify ICNS representations")
    try:
        with tempfile.TemporaryDirectory(prefix="lumisync-icon-") as temporary_directory:
            temporary = Path(temporary_directory)
            copied_icns = temporary / "LumiSync.icns"
            iconset = temporary / "LumiSync.iconset"
            shutil.copy2(path, copied_icns)
            result = subprocess.run(
                ["iconutil", "-c", "iconset", str(copied_icns), "-o", str(iconset)],
                capture_output=True,
                text=True,
                check=False,
            )
            if result.returncode != 0:
                diagnostic = result.stderr.strip() or result.stdout.strip() or "unknown iconutil error"
                raise VerificationError(f"{path}: iconutil extraction failed: {diagnostic}")

            representations = {
                representation.name: representation for representation in iconset.glob("*.png")
            }
            missing = sorted(set(REQUIRED_ICNS_REPRESENTATIONS) - set(representations))
            if missing:
                raise VerificationError(
                    f"{path}: missing ICNS representation files: {', '.join(missing)}"
                )

            unexpected = sorted(set(representations) - set(REQUIRED_ICNS_REPRESENTATIONS))
            if unexpected:
                raise VerificationError(
                    f"{path}: unexpected ICNS representation files: {', '.join(unexpected)}"
                )
            expected_iconset = expected_iconset_from_master(master, temporary)
            expected_representations = {
                representation.name: representation for representation in expected_iconset.glob("*.png")
            }
            for name, representation in sorted(representations.items()):
                width, height, _ = parse_png(representation, decode_pixels=False)
                if width != height:
                    raise VerificationError(f"{path}: ICNS representation {name} is not square")
                expected_size = REQUIRED_ICNS_REPRESENTATIONS[name]
                if width != expected_size:
                    raise VerificationError(
                        f"{path}: ICNS representation {name} must be "
                        f"{expected_size}x{expected_size}, got {width}x{height}"
                    )
                compare_icns_representation(path, representation, expected_representations[name], name)
    except OSError as error:
        raise VerificationError(f"cannot verify ICNS {path}: {error}") from error


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--master", type=Path, required=True, help="1024x1024 RGBA master PNG")
    parser.add_argument("--icns", type=Path, required=True, help="macOS ICNS file")
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        verify_master(arguments.master)
        verify_icns(arguments.icns, arguments.master)
    except VerificationError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print("App icon verification passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
