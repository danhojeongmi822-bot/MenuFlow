#!/usr/bin/env python3
"""Reference-model checks for generated FAT32 fixtures."""
from pathlib import Path
import hashlib, json, struct

ROOT = Path(__file__).resolve().parent

def check(case):
    image = (ROOT / case["image"]).read_bytes()
    assert hashlib.sha256(image).hexdigest() == case["sha256"]
    sec = case["sector_size"]
    p = case["partition_lba"]
    bpb = image[p * sec:(p + 1) * sec]
    assert struct.unpack_from("<H", bpb, 11)[0] == sec
    assert bpb[13] == case["sectors_per_cluster"]
    fat_lba = case["fat_start_lba"]
    data_lba = case["data_start_lba"]
    fat = image[fat_lba * sec:(fat_lba + 1) * sec]
    for name, info in case["files"].items():
        chain = info["clusters"]
        payload = b"".join(image[(data_lba + c - 2) * sec:(data_lba + c - 1) * sec] for c in chain)
        assert len(payload) == info["size"]
        assert hashlib.sha256(payload).hexdigest() == info["sha256"]
        for cur, nxt in zip(chain, chain[1:]):
            assert (int.from_bytes(fat[cur * 4:cur * 4 + 4], "little") & 0x0FFFFFFF) == nxt

def main():
    manifest = json.loads((ROOT / "fixture_manifest.json").read_text(encoding="utf-8"))
    for case in manifest["cases"]:
        check(case)
        print(f"PASS {case['image']} sha256={case['sha256'][:12]}")
    for case in manifest["anomalies"]:
        image = (ROOT / case["image"]).read_bytes()
        assert hashlib.sha256(image).hexdigest() == case["sha256"]
        assert case["expected_error"] in case["image"]
        print(f"PASS anomaly {case['expected_error']} sha256={case['sha256'][:12]}")

if __name__ == "__main__":
    main()
