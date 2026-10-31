#!/usr/bin/env python3
"""Verify a MenuFlow submission without requiring the development repository."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import xml.etree.ElementTree as ET
import zipfile


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def verify(root: Path) -> dict:
    manifest = json.loads((root / 'docs/submission_manifest.json').read_text(encoding='utf-8'))
    entries = manifest['files']
    paths = [entry['path'] for entry in entries]
    assert len(paths) == len(set(paths)), 'Duplicate manifest path'
    for entry in entries:
        path = root / entry['path']
        assert path.resolve().is_relative_to(root.resolve()), entry['path']
        data = path.read_bytes()
        checked_data = data
        if entry['path'] == 'HX4S20_HDMI/HX4S20_HDMI_Config.al':
            local_path = re.search(rb'<Project\b[^>]*\bPath="([^"]*)"', data)[1].decode('utf-8')
            assert local_path == '.' or Path(local_path).resolve() == (root / 'HX4S20_HDMI').resolve(), 'Unexpected TD Project Path'
            checked_data = re.sub(rb'(<Project\b[^>]*\bPath=")[^"]*(")', rb'\g<1>.\2', data, count=1)
        assert len(checked_data) == entry['bytes'], f"Size mismatch: {entry['path']}"
        assert digest(checked_data) == entry['sha256'], f"SHA-256 mismatch: {entry['path']}"
        assert len(data) < 100 * 1024 * 1024, f"GitHub file limit: {entry['path']}"
        assert not any(part in {'.trellis', '.agents', '.claude', '.codex', '.cursor', '任务记录'}
                       for part in Path(entry['path']).parts), entry['path']
    project = root / 'HX4S20_HDMI'
    al = ET.fromstring((project / 'HX4S20_HDMI_Config.al').read_text(encoding='utf-8')
                       .replace('UsedInP&R', 'UsedInP&amp;R'))
    assert al.get('Path') == '.' or Path(al.get('Path')).resolve() == project.resolve(), 'Project must use the local project directory'
    assert al.findtext('./HardWare/Device') == 'EG4S20BG256'
    assert al.findtext('./TOP_MODULE/MODULE') == 'hx4s20_board_top'
    refs = [node.get('Path') for node in al.findall('./Source_Files/*/File')]
    for ref in refs:
        assert (project / ref).is_file(), f'Missing project source: {ref}'
    assert 'SD/sdram.v' in refs and 'IP/sdram.v' not in refs
    includes = 0
    readmems = 0
    for rel in paths:
        path = root / rel
        if path.suffix.lower() not in {'.v', '.vh'}:
            continue
        text = path.read_text(encoding='utf-8', errors='replace')
        # Keep literal directives; encrypted payload is not rewritten or interpreted.
        for ref in re.findall(r'`include\s+"([^"]+)"', text):
            candidates = [path.parent / ref, project / ref, project / 'include' / ref,
                          project / 'SD' / ref]
            assert any(p.is_file() for p in candidates), f'Missing include: {rel}: {ref}'
            includes += 1
        for ref in re.findall(r'\$readmem[hb]\s*\(\s*"([^"]+)"', text):
            candidates = [path.parent / ref, root / ref, project / ref]
            assert any(p.is_file() for p in candidates), f'Missing memory input: {rel}: {ref}'
            readmems += 1
    bit_manifest = json.loads((root / '实验位流/manifest.json').read_text(encoding='utf-8'))
    bits = [root / rel for rel in paths if rel.endswith('.bit')]
    assert len(bits) == 1, 'Exactly one downloadable bitstream is required'
    bit = root / bit_manifest['canonical_download']
    assert bits[0] == bit
    assert digest(bit.read_bytes()) == bit_manifest['sha256']
    timing = (root / bit_manifest['timing_report']).read_text(encoding='utf-8', errors='replace')
    metrics = {key: float(value) for key, value in
               re.findall(r'(SWNS|STNS|HWNS|HTNS):\s*(-?[\d.]+)ns', timing)}
    assert set(metrics) == {'SWNS', 'STNS', 'HWNS', 'HTNS'}, 'Incomplete timing summary'
    assert all(value >= 0 for value in metrics.values()), f'Negative timing margin: {metrics}'
    for rel in paths:
        path = root / rel
        if path.suffix.lower() == '.bmp' and '/board/fat32/' not in rel:
            data = path.read_bytes()
            assert data[:2] == b'BM', rel
            width, height = struct.unpack_from('<ii', data, 18)
            assert (width, height) == (640, 480), rel
            assert struct.unpack_from('<H', data, 28)[0] == 24, rel
            assert struct.unpack_from('<I', data, 30)[0] == 0, rel
            assert len(data) == 921654, rel
        if path.suffix.lower() == '.pcm':
            assert path.stat().st_size > 0 and path.stat().st_size % 2 == 0, rel
        if path.suffix.lower() == '.pdf':
            pdf_data = path.read_bytes()
            assert pdf_data.startswith(b'%PDF-') and b'%%EOF' in pdf_data[-2048:], rel
            assert 0 < len(pdf_data) < 50_000_000, 'PDF must be smaller than 50 MB'
        if path.suffix.lower() == '.docx':
            with zipfile.ZipFile(path) as document:
                assert document.testzip() is None
                ET.fromstring(document.read('word/document.xml'))
        if path.suffix.lower() == '.md':
            text = path.read_text(encoding='utf-8')
            for target in re.findall(r'!?\[[^\]]*\]\(([^)]+)\)', text):
                if target.startswith(('http:', 'https:', '#', 'mailto:')):
                    continue
                target = target.split('#', 1)[0]
                if target:
                    assert (path.parent / target).exists(), f'Broken Markdown link: {rel}: {target}'
    return {'files': len(paths), 'bytes': sum(e['bytes'] for e in entries),
            'project_references': len(refs), 'include_references': includes,
            'literal_readmem_references': readmems, 'bitstream_sha256': bit_manifest['sha256'],
            'timing_metrics_ns': metrics, 'business_source_commit': manifest['source_commit'],
            'new_td_build_performed': False, 'new_board_test_performed': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[3])
    arguments = parser.parse_args()
    print(json.dumps(verify(arguments.root.resolve()), ensure_ascii=False, indent=2))
    print('PASS: submission payload, dependencies, attachments and reported timing verified.')
