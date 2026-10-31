#!/usr/bin/env python3
"""Create deterministic, small FAT32 images used by the RTL reference tests.

The images are intentionally sparse in the logical layout (the generated file is
small), but every sector in the manifest is deterministic and can be copied to a
real card by a separate, explicitly approved step.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import struct

SECTOR = 512
ROOT = 2


def put(buf: bytearray, off: int, value: int, size: int = 4) -> None:
    buf[off:off + size] = value.to_bytes(size, "little")


def make_image(path: Path, fragmented: bool = False, super_floppy: bool = False) -> dict:
    reserved = 32
    fats = 1
    fat_sectors = 1
    spc = 1
    partition_lba = 0 if super_floppy else 8
    data_lba = partition_lba + reserved + fat_sectors
    total_sectors = 96
    image = bytearray((partition_lba + total_sectors) * SECTOR)

    def sector(lba: int) -> bytearray:
        start = lba * SECTOR
        return image[start:start + SECTOR]

    def write_sector(lba: int, data: bytes | bytearray) -> None:
        image[lba * SECTOR:(lba + 1) * SECTOR] = data[:SECTOR]

    bpb = bytearray(SECTOR)
    bpb[0:3] = b"\xeb\x58\x90"
    bpb[3:11] = b"TRELFS  "
    put(bpb, 11, SECTOR, 2)
    bpb[13] = spc
    put(bpb, 14, reserved, 2)
    bpb[16] = fats
    put(bpb, 32, total_sectors, 4)
    put(bpb, 36, fat_sectors, 4)
    put(bpb, 44, ROOT, 4)
    put(bpb, 510, 0xAA55, 2)

    if super_floppy:
        write_sector(0, bpb)
    else:
        mbr = bytearray(SECTOR)
        entry = 446
        mbr[entry + 4] = 0x0C
        put(mbr, entry + 8, partition_lba, 4)
        put(mbr, entry + 12, total_sectors, 4)
        put(mbr, 510, 0xAA55, 2)
        write_sector(0, mbr)
        write_sector(partition_lba, bpb)

    fat = bytearray(SECTOR)
    put(fat, 0, 0x0FFFFFF8)
    put(fat, 4, 0x0FFFFFFF)
    put(fat, ROOT * 4, 0x0FFFFFFF)
    clusters = {
        "PIC1.BMP": [3, 4] if not fragmented else [3, 7],
        "PIC2.BMP": [5],
        "PIC3.BMP": [6],
        "PIC4.BMP": [8],
    }
    for chain in clusters.values():
        for cur, nxt in zip(chain, chain[1:] + [0x0FFFFFFF]):
            put(fat, cur * 4, nxt)
    write_sector(partition_lba + reserved, fat)

    directory = bytearray(SECTOR)
    for n, (name, chain) in enumerate(clusters.items()):
        off = n * 32
        stem, ext = name.split(".")
        directory[off:off + 8] = stem.ljust(8).encode("ascii")
        directory[off + 8:off + 11] = ext.ljust(3).encode("ascii")
        directory[off + 11] = 0x20
        put(directory, off + 26, chain[0], 2)
        put(directory, off + 20, chain[0] >> 16, 2)
        put(directory, off + 28, len(chain) * SECTOR, 4)
    directory[4 * 32] = 0
    write_sector(data_lba, directory)

    expected = {}
    for n, (name, chain) in enumerate(clusters.items()):
        payload = bytearray()
        for cluster in chain:
            block = bytearray(SECTOR)
            block[:16] = bytes(((n + 1) * 17 + i) & 0xFF for i in range(16))
            payload.extend(block)
            write_sector(data_lba + cluster - 2, block)
        expected[name] = {
            "first_cluster": chain[0],
            "size": len(payload),
            "clusters": chain,
            "sha256": hashlib.sha256(payload).hexdigest(),
        }

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(image)
    (path.with_suffix(".hex")).write_text("\n".join(f"{b:02x}" for b in image) + "\n", encoding="ascii")
    manifest = {
        "image": path.name,
        "sha256": hashlib.sha256(image).hexdigest(),
        "sector_size": SECTOR,
        "partition_lba": partition_lba,
        "root_cluster": ROOT,
        "sectors_per_cluster": spc,
        "fat_start_lba": partition_lba + reserved,
        "data_start_lba": data_lba,
        "files": expected,
    }
    return manifest


def make_anomaly(path: Path, kind: str) -> dict:
    """Derive one deterministic malformed image from the contiguous fixture."""
    source = bytearray((Path(__file__).resolve().parent / "fat32_contiguous.img").read_bytes())
    partition_lba = 8
    fat_lba = partition_lba + 32
    data_lba = fat_lba + 1
    if kind == "missing_file":
        source[data_lba * SECTOR + 3 * 32] = 0xE5
    elif kind == "invalid_bpb":
        source[partition_lba * SECTOR + 11:partition_lba * SECTOR + 13] = b"\x00\x01"
    elif kind == "fat_early_eof":
        put(source, fat_lba * SECTOR + 3 * 4, 0x0FFFFFFF)
    elif kind == "fat_loop":
        put(source, fat_lba * SECTOR + 3 * 4, 4)
        put(source, fat_lba * SECTOR + 4 * 4, 3)
    elif kind == "cluster_oob":
        put(source, fat_lba * SECTOR + 3 * 4, 0x00000041)
    else:
        raise ValueError(kind)
    path.write_bytes(source)
    path.with_suffix(".hex").write_text("\n".join(f"{b:02x}" for b in source) + "\n", encoding="ascii")
    return {
        "image": path.name,
        "sha256": hashlib.sha256(source).hexdigest(),
        "sector_size": SECTOR,
        "partition_lba": partition_lba,
        "expected_error": kind,
    }


def main() -> None:
    out = Path(__file__).resolve().parent
    cases = [
        ("fat32_contiguous.img", False, False),
        ("fat32_fragmented.img", True, False),
        ("fat32_superfloppy.img", True, True),
    ]
    manifests = [make_image(out / name, fragmented=frag, super_floppy=superf) for name, frag, superf in cases]
    anomalies = [make_anomaly(out / f"fat32_{kind}.img", kind) for kind in (
        "missing_file", "invalid_bpb", "fat_early_eof", "fat_loop", "cluster_oob"
    )]
    (out / "fixture_manifest.json").write_text(
        json.dumps({"cases": manifests, "anomalies": anomalies}, indent=2) + "\n", encoding="utf-8"
    )


if __name__ == "__main__":
    main()
