#!/usr/bin/env python3
"""Exercise reproducible FAT32 images against production scanner/streamer RTL.

No card access, TD build or RTL mutation. Results distinguish short file_size
termination from actual cyclic-chain rejection. Derived images are rebuilt in a
temporary directory; their hashes and exact mutations remain in the JSON report.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]


def u32(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def put(data: bytearray, offset: int, value: int) -> None:
    struct.pack_into("<I", data, offset, value)


def root_chain_image(source: bytes, eof: bool = False) -> bytearray:
    image = bytearray(source)
    entries = [bytes(source[41 * 512 + n * 32:41 * 512 + (n + 1) * 32]) for n in range(4)]
    put(image, 8 * 512 + 44, 10)  # BPB root is genuinely not cluster 2.
    put(image, 40 * 512 + 10 * 4, 11)
    put(image, 40 * 512 + 11 * 4, 0xAFFFFFFF)  # high FAT bits ignored
    first = bytearray(512)
    for n in range(16):
        first[n * 32] = 0xE5
    first[:64] = entries[0] + entries[1]
    # Decoys after actual PIC1/PIC2 must not override valid directory metadata.
    for slot, entry, attribute in ((2, entries[2], 0x20), (3, entries[3], 0x0F),
                                   (14, entries[0], 0x10), (15, entries[1], 0x08)):
        decoy = bytearray(entry)
        decoy[11] = attribute
        put(decoy, 26, 30)  # invalid target metadata if accepted
        if slot == 2:
            decoy[0] = 0xE5
        first[slot * 32:(slot + 1) * 32] = decoy
    second = bytearray(512)
    second[:64] = entries[2] + entries[3]
    if eof:
        for n in range(2, 16):
            second[n * 32] = 0xE5  # no directory 0x00; finish via FAT EOF
    image[(41 + 10 - 2) * 512:(41 + 10 - 1) * 512] = first
    image[(41 + 11 - 2) * 512:(41 + 11 - 1) * 512] = second
    image[41 * 512:42 * 512] = bytes(512)  # wrong hardcoded root cannot pass
    return image


def reference_files(image: bytes, root: int) -> list[tuple[int, int]]:
    """Independent directory reference, traversing real root and FAT links."""
    partition = 0 if image[:1] == b"\xeb" else u32(image, 454)
    bpb = partition * 512
    fat = partition + int.from_bytes(image[bpb + 14:bpb + 16], "little")
    data = fat + image[bpb + 16] * u32(image, bpb + 36)
    found = {}
    visited = set()
    cluster = root
    while cluster not in visited:
        visited.add(cluster)
        directory = image[(data + cluster - 2) * 512:(data + cluster - 1) * 512]
        for offset in range(0, 512, 32):
            entry = directory[offset:offset + 32]
            if entry[0] == 0:
                return [found[n] for n in range(1, 5)]
            if entry[0] == 0xE5 or entry[11] == 0x0F or entry[11] & 0x18:
                continue
            for number in range(1, 5):
                if entry[:11] == f"PIC{number}    BMP".encode():
                    first = int.from_bytes(entry[26:28], "little") | (int.from_bytes(entry[20:22], "little") << 16)
                    found[number] = first, u32(entry, 28)
        cluster = u32(image, fat * 512 + cluster * 4) & 0x0FFFFFFF
        if cluster >= 0x0FFFFFF8:
            return [found[n] for n in range(1, 5)]
    raise AssertionError("reference root loop")


def reference_payload(image: bytes, first: int, count: int) -> bytes:
    partition = 0 if image[:1] == b"\xeb" else u32(image, 454)
    bpb = partition * 512
    fat = partition + int.from_bytes(image[bpb + 14:bpb + 16], "little")
    data = fat + image[bpb + 16] * u32(image, bpb + 36)
    payload = bytearray()
    cluster = first
    while len(payload) < count:
        assert 2 <= cluster <= 64, cluster
        payload.extend(image[(data + cluster - 2) * 512:(data + cluster - 1) * 512])
        cluster = u32(image, fat * 512 + cluster * 4) & 0x0FFFFFFF
    return bytes(payload[:count])


def chain_metadata(image: bytes, first: int) -> dict:
    partition = 0 if image[:1] == b"\xeb" else u32(image, 454)
    fat = partition + int.from_bytes(image[partition * 512 + 14:partition * 512 + 16], "little")
    chain = []
    cluster = first
    while 2 <= cluster <= 64 and cluster not in chain:
        chain.append(cluster)
        cluster = u32(image, fat * 512 + cluster * 4) & 0x0FFFFFFF
    return {"clusters": chain, "next_or_terminal": cluster, "cycle": cluster in chain}


def main() -> None:
    compiler = shutil.which("iverilog") or "C:/iverilog/bin/iverilog.exe"
    runtime = shutil.which("vvp") or "C:/iverilog/bin/vvp.exe"
    manifest = json.loads((HERE / "fixture_manifest.json").read_text(encoding="utf-8"))
    cases = []
    for case in manifest["cases"] + manifest["anomalies"]:
        image = (HERE / case["image"]).read_bytes()
        assert hashlib.sha256(image).hexdigest() == case["sha256"]
        kind = case.get("expected_error")
        cases.append(dict(name=Path(case["image"]).stem, image=image,
                          scan_error=1 if kind in ("missing_file", "invalid_bpb") else 0,
                          file_error={"fat_early_eof": 7, "cluster_oob": 4}.get(kind, 0),
                          error_bytes=512, root=2, mutations=[]))
    source = (HERE / "fat32_contiguous.img").read_bytes()
    partial = bytearray(source)
    put(partial, 41 * 512 + 28, 777)
    cases.append(dict(name="file_size_777_exact_stop", image=partial, scan_error=0,
                      file_error=0, root=2, mutations=["PIC1 directory file_size=777; allocated chain remains 3->4->EOF"]))
    bad_file = bytearray(source)
    put(bad_file, 40 * 512 + 3 * 4, 0x0FFFFFF7)
    cases.append(dict(name="file_bad_cluster", image=bad_file, scan_error=0,
                      file_error=4, error_bytes=512, root=2, mutations=["FAT[3]=0x0FFFFFF7"]))
    for eof in (False, True):
        cases.append(dict(name="root10_cross_cluster_" + ("fat_eof" if eof else "directory_end"),
                          image=root_chain_image(source, eof), scan_error=0, file_error=0, root=10,
                          mutations=["BPB.root=10; root FAT 10->11->EOF; targets split 2+2",
                                     "deleted/LFN/subdir/volume decoys; original cluster2 zeroed",
                                     "FAT EOF high bits=A; directory " + ("no 00 marker" if eof else "00 marker")]))
    long_loop = bytearray((HERE / "fat32_fat_loop.img").read_bytes())
    put(long_loop, 41 * 512 + 28, 8192)
    cases.append(dict(name="fat_loop_exceeds_file_size_window", image=long_loop,
                      scan_error=0, file_error=5, error_bytes=9 * 512, root=2,
                      mutations=["PIC1 directory file_size=8192; existing FAT 3->4->3",
                                 "TB MAX_VISITED_CLUSTERS=8; expect bounded rejection after 9 clusters"]))
    for kind, next_cluster, expected in (("loop", 10, 5), ("oob", 65, 4), ("bad", 0x0FFFFFF7, 4)):
        image = root_chain_image(source)
        put(image, 40 * 512 + 10 * 4, next_cluster)
        # Prevent early success: first root contains PIC1/PIC2 only, no 00 marker.
        cases.append(dict(name="root10_" + kind, image=image, scan_error=expected,
                          file_error=0, root=10, mutations=[f"root FAT[10]={next_cluster:#x}"]))

    results = {"description": "Actual RTL scanner/streamer fixture matrix; sector transport is a TB byte source",
               "scope": "No adapter/SPI/SDRAM/physical board coverage implied",
               "test_parameters": {"MAX_DIR_CLUSTERS": 8, "MAX_VISITED_CLUSTERS": 8},
               "loop_detection": "Bounded traversal rejection; does not claim a visited-set implementation or production-limit endurance",
               "results": []}
    with tempfile.TemporaryDirectory(prefix="fat32_rtl_matrix_") as temporary:
        temp = Path(temporary)
        executable = temp / "matrix.vvp"
        subprocess.run([compiler, "-g2012", "-s", "tb_fat32_fixture_matrix", "-o", str(executable),
                        str(PROJECT / "board/tests/tb_fat32_fixture_matrix.v"),
                        str(PROJECT / "SD/fat32_volume_scanner.v"),
                        str(PROJECT / "SD/fat32_file_streamer.v")], check=True, capture_output=True, text=True)
        for case in cases:
            hex_path, capture = temp / (case["name"] + ".hex"), temp / "capture.bin"
            image = case["image"]
            hex_path.write_text("\n".join(f"{value:02x}" for value in image) + "\n", encoding="ascii")
            command = [runtime, str(executable), f"+IMAGE={hex_path.as_posix()}",
                       f"+OUTPUT={capture.as_posix()}", f"+IMAGE_BYTES={len(image)}",
                       f"+SCAN_ERROR={case['scan_error']}", f"+FILE_ERROR={case['file_error']}",
                       f"+ROOT={case['root']}"]
            run = subprocess.run(command, capture_output=True, text=True, timeout=30)
            actual = capture.read_bytes() if capture.exists() else b""
            reference = b""
            if not case["scan_error"]:
                files = reference_files(image, case["root"])
                for first, size in files[:1] if case["file_error"] else files:
                    reference += reference_payload(image, first, case.get("error_bytes", 0) if case["file_error"] else size)
            byte_match = actual == reference
            metadata_match = True
            if not case["scan_error"]:
                observed = [(int(first), int(size)) for first, size in
                            re.findall(r"FILE index=\d+ cluster=(\d+) size=(\d+)", run.stdout)]
                metadata_match = observed == (files[:1] if case["file_error"] else files)
            passed = run.returncode == 0 and "FIXTURE_PASS" in run.stdout and byte_match and metadata_match
            result = {key: value for key, value in case.items() if key != "image"}
            if not case["scan_error"]:
                result["expected_files"] = [dict(name=f"PIC{index + 1}.BMP", first_cluster=first,
                                                 file_size=size, **chain_metadata(image, first))
                                            for index, (first, size) in enumerate(files)]
            result.update(image_sha256=hashlib.sha256(image).hexdigest(), image_bytes=len(image),
                          returncode=run.returncode, passed=passed, byte_match=byte_match,
                          metadata_match=metadata_match, captured_bytes=len(actual),
                          expected_bytes=len(reference), captured_sha256=hashlib.sha256(actual).hexdigest(),
                          expected_sha256=hashlib.sha256(reference).hexdigest(), stdout=run.stdout, stderr=run.stderr)
            results["results"].append(result)
            print(("PASS " if passed else "FAIL ") + case["name"] + f" bytes={len(actual)}")
            if not passed:
                print(run.stdout, run.stderr)
    results["passed"] = all(result["passed"] for result in results["results"])
    results["rtl_sha256"] = {name: hashlib.sha256((PROJECT / "SD" / name).read_bytes()).hexdigest()
                             for name in ("fat32_volume_scanner.v", "fat32_file_streamer.v")}
    (HERE / "rtl_fixture_results.json").write_text(json.dumps(results, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    if not results["passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
