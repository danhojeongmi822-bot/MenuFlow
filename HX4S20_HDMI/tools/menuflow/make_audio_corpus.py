#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""TF 卡 PCM 素材生成与校验（MenuFlow 音频升级）。

输出：
  1. HX4S20_HDMI/assets/tf_audio/PIC3.PCM / PIC4.PCM
     —— 48 kHz / 16 bit 有符号 / 单声道 / 小端 / 裸 PCM（无 RIFF 头）
  2. HX4S20_HDMI/assets/tf_audio/manifest.json
     —— 每个文件的字节数、样本数、时长、峰值、SHA-256

注意：这是**原始 PCM**，不是通用 WAV 解码。FPGA 侧按 FAT32 目录项里的
PICn.PCM 找到簇链，直接按字节流播放，不解析 RIFF/fmt/data 结构。

用法（在 HX4S20_HDMI/ 下）：
  python tools/menuflow/make_audio_corpus.py                 # 生成内置测试音
  python tools/menuflow/make_audio_corpus.py --wav a.wav --out PIC3.PCM
     把任意 WAV 转换成上述格式（需要 ffmpeg 或 soundfile/pydub；见 --help）
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import struct
import sys
from array import array
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent.parent   # HX4S20_HDMI/
OUT_DIR = BASE / "assets" / "tf_audio"

SAMPLE_RATE = 48_000
AMPLITUDE = 14_000        # 约 -7 dBFS，留足余量避免削波
FADE_MS = 20


def write_pcm(path: Path, samples: array) -> dict:
    """写 16 位小端 PCM，返回统计信息。"""
    if len(samples) == 0:
        raise ValueError("空样本序列")
    data = bytearray(len(samples) * 2)
    struct.pack_into("<%dh" % len(samples), data, 0, *samples)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(bytes(data))
    peak = max(abs(s) for s in samples)
    return {
        "file": path.name,
        "bytes": len(data),
        "samples": len(samples),
        "seconds": round(len(samples) / SAMPLE_RATE, 3),
        "peak": peak,
        "peak_dbfs": round(20 * math.log10(peak / 32768), 2) if peak else None,
        "sha256": hashlib.sha256(data).hexdigest(),
    }


def apply_fade(samples: array, ms: int = FADE_MS) -> None:
    n = int(SAMPLE_RATE * ms / 1000)
    n = min(n, len(samples) // 2)
    for i in range(n):
        k = i / n
        samples[i] = int(samples[i] * k)
        samples[-1 - i] = int(samples[-1 - i] * k)


def promo_arpeggio(notes: list[float], note_ms: int, loops: int) -> array:
    """带 5 次谐波的琶音，避免纯正弦听起来过于单薄。"""
    per = int(SAMPLE_RATE * note_ms / 1000)
    out = array("h")
    phase = 0.0
    for _ in range(loops):
        for f in notes:
            for _ in range(per):
                v = (math.sin(phase)
                     + 0.28 * math.sin(2 * phase)
                     + 0.12 * math.sin(3 * phase))
                out.append(int(AMPLITUDE * v / 1.40))
                phase += 2 * math.pi * f / SAMPLE_RATE
    apply_fade(out)
    return out


def make_pic3() -> array:
    """C5-E5-G5-C6 上行琶音，循环 8 次（约 8 秒），音色明亮，便于听出连续播放。"""
    return promo_arpeggio([523.25, 659.25, 783.99, 1046.50], 250, 8)


def make_pic4() -> array:
    """A4-C5-E5-A5 上行琶音 + 低八度衬底感（换和声，便于区分页面切换）。"""
    return promo_arpeggio([440.00, 523.25, 659.25, 880.00], 250, 8)


def read_wav_pcm(path: Path) -> tuple[array, int, int, int]:
    """读取 PCM WAV（不依赖第三方库）：返回 (samples, channels, rate, bits)。"""
    raw = path.read_bytes()
    if raw[:4] != b"RIFF" or raw[8:12] != b"WAVE":
        raise ValueError("不是 RIFF/WAVE 文件")
    pos = 12
    fmt = None
    data = None
    while pos + 8 <= len(raw):
        cid = raw[pos:pos + 4]
        size = int.from_bytes(raw[pos + 4:pos + 8], "little")
        body = raw[pos + 8:pos + 8 + size]
        if cid == b"fmt ":
            fmt = body
        elif cid == b"data":
            data = body
        pos += 8 + size + (size & 1)
    if fmt is None or data is None:
        raise ValueError("缺少 fmt/data 块")
    tag, channels, rate = struct.unpack_from("<HH I", fmt, 0)
    bits = struct.unpack_from("<H", fmt, 14)[0]
    if tag != 1:
        raise ValueError(f"仅支持 PCM（format=1），当前 {tag}")
    if bits != 16:
        raise ValueError(f"仅支持 16 bit，当前 {bits}")
    samples = array("h")
    samples.frombytes(data[: len(data) // 2 * 2])
    if sys.byteorder == "big":
        samples.byteswap()
    return samples, channels, rate, bits


def convert_wav(path: Path) -> array:
    """把 WAV 转为 48 kHz 单声道。重采样只做线性插值（素材准备期一次性处理）。"""
    samples, channels, rate, _ = read_wav_pcm(path)
    if channels > 1:
        mono = array("h")
        for i in range(0, len(samples) - channels + 1, channels):
            mono.append(sum(samples[i:i + channels]) // channels)
        samples = mono
    if rate != SAMPLE_RATE:
        ratio = SAMPLE_RATE / rate
        n_out = int(len(samples) * ratio)
        out = array("h")
        for i in range(n_out):
            x = i / ratio
            i0 = int(x)
            i1 = min(i0 + 1, len(samples) - 1)
            frac = x - i0
            out.append(int(samples[i0] * (1 - frac) + samples[i1] * frac))
        samples = out
        print(f"重采样 {rate} -> {SAMPLE_RATE} Hz，{len(samples)} 样本")
    apply_fade(samples)
    return samples


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--wav", type=Path, help="转换单个 WAV 文件")
    ap.add_argument("--out", default="PIC3.PCM", help="输出文件名（8.3 名，默认 PIC3.PCM）")
    args = ap.parse_args()

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    entries = []

    if args.wav:
        name = args.out.upper()
        if not (name.startswith("PIC") and name.endswith(".PCM") and len(name) == 8):
            raise SystemExit("输出名必须是 8.3 形式，如 PIC3.PCM")
        entries.append(write_pcm(OUT_DIR / name, convert_wav(args.wav)))
    else:
        entries.append(write_pcm(OUT_DIR / "PIC3.PCM", make_pic3()))
        entries.append(write_pcm(OUT_DIR / "PIC4.PCM", make_pic4()))

    manifest = {
        "format": "s16le mono 48000 Hz, raw PCM (no RIFF header)",
        "note": "FPGA 按 FAT32 目录项 PICn.PCM 直接播放字节流；不解析 WAV 头。",
        "files": entries,
    }
    (OUT_DIR / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    for e in entries:
        print(f"{e['file']}: {e['bytes']} B, {e['samples']} samples, "
              f"{e['seconds']} s, peak {e['peak']}, sha256 {e['sha256']}")
    print(f"manifest -> {OUT_DIR / 'manifest.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
