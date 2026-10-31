#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""TD 构建包装：登记新增源文件后立即构建。

背景：TD 打开 `.al` 时会重写工程文件，把 `audio/`、`display/audio_waveform_overlay.v`
等新增条目丢掉（历史多次复现，见任务12/16）。手工“先登记再启动 TD”无法保证
不被覆盖，因此在同一次调用中完成：
  1. 备份当前 `.al`；
  2. 幂等登记新增文件（缺失才插入）；
  3. 立刻调用 `td_commands_prompt.exe board/build_project.tcl`；
  4. 校验退出码、`HX4S20_BITGEN_FINISHED`、build 后 `.al` 是否仍有新条目。

用法（在 HX4S20_HDMI/ 下）：
  python tools/menuflow/run_td_build.py [--log board/td_logs/xxx.log]
"""
from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent.parent   # HX4S20_HDMI/
AL = BASE / "HX4S20_HDMI_Config.al"
NEW_FILES = [
    "audio/pcm_ring_buffer.v",
    "audio/pcm_stream_player.v",
    "audio/audio_source_mux.v",
    "audio/audio_page_gate.v",
    "display/audio_waveform_overlay.v",
]


def register(entries: list[str]) -> list[str]:
    text = AL.read_text(encoding="utf-8")
    vend = text.index("</Verilog>")
    vstart = text.index("<Verilog>")
    present = [f for f in entries if f'Path="{f}"' in text[vstart:vend]]
    missing = [f for f in entries if f not in present]
    if not missing:
        return present

    orders = [int(m) for m in re.findall(r'<Attr Name="CompileOrder" Val="(\d+)"/>', text[vstart:vend])]
    order = max(orders) + 1
    block = ""
    for f in missing:
        block += f"""            <File Path="{f}">
                <FileInfo>
                    <Attr Name="UsedInSyn" Val="true"/>
                    <Attr Name="UsedInP&R" Val="true"/>
                    <Attr Name="BelongTo" Val="design_1"/>
                    <Attr Name="CompileOrder" Val="{order}"/>
                </FileInfo>
            </File>
"""
        order += 1
    AL.write_text(text[:vend] + block + text[vend:], encoding="utf-8")
    return present + missing


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", type=Path)
    args = ap.parse_args()
    log = args.log or (BASE / "board" / "td_logs" /
                       f"td_{datetime.now():%Y%m%d_%H%M%S}_audio_upgrade.log")

    backup = AL.with_suffix(".al.bak")
    shutil.copy2(AL, backup)
    got = register(NEW_FILES)
    print(f"registered: {len(got)} / {len(NEW_FILES)}")

    log.parent.mkdir(parents=True, exist_ok=True)
    r = subprocess.run(["td_commands_prompt.exe", "board/build_project.tcl"],
                       cwd=BASE, capture_output=True, text=True)
    out = (r.stdout or "") + (r.stderr or "")
    log.write_text(out, encoding="utf-8")

    errors = [l for l in out.splitlines() if "ERROR" in l and "HDL-8007" in l]
    ok_syn = "HX4S20_SYNTHESIS_FINISHED" in out
    ok_bit = "HX4S20_BITGEN_FINISHED" in out
    after = AL.read_text(encoding="utf-8")
    lost = [f for f in NEW_FILES if f'Path="{f}"' not in after]

    print(f"td exit={r.returncode} synthesis={ok_syn} bitgen={ok_bit}")
    print(f"log: {log}")
    if errors:
        print("elaborate errors:")
        for e in errors[:10]:
            print("  " + e[:160])
    if lost:
        print("WARNING: TD rewrote .al and dropped:", ", ".join(lost))
    return 0 if (r.returncode == 0 and ok_syn and ok_bit and not errors) else 1


if __name__ == "__main__":
    sys.exit(main())
