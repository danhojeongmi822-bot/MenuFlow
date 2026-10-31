"""Run the OSD testbenches with ModelSim and keep reproducible logs.

ModelSim ALTERA Starter 10.3c returns exit code 0 even after $fatal, so the
pass/fail decision is based on the transcript: "Errors: 0", no "** Fatal:" /
"** Error:", and a "PASS" marker from the testbench.
"""
from pathlib import Path
import re
import shutil
import subprocess
import sys

MS = Path(r"D:/altera/14.1/modelsim_ase/win32aloem")
BASE = Path(__file__).resolve().parent.parent
LOG_DIR = BASE / "board" / "sim_logs"
# 编译工作区必须留在工程目录内：本机沙箱下 vlib 无法进入系统临时目录。
WORK_ROOT = BASE / "board" / "sim_work"

TESTS = {
    "tb_osd_font": {
        "sources": ["board/tests/tb_osd_font.v", "display/osd_font_rom.v"],
        "incdir": [],
    },
    "tb_osd_status_cdc": {
        "sources": ["board/tests/tb_osd_status_cdc.v", "display/osd_status_cdc.v"],
        "incdir": [],
    },
    "tb_osd_error_code": {
        "sources": [
            "board/tests/tb_osd_error_code.v",
            "SD/sd_card_bmp.v",
            "SD/bmp_read.v",
            "SD/sd_card_top.v",
            "SD/sd_card_cmd.v",
            "SD/sd_card_sec_read_write.v",
            "SD/spi_master.v",
        ],
        "incdir": [],
    },
    "tb_osd_video_pipeline": {
        "sources": [
            "board/tests/tb_osd_video_pipeline.v",
            "display/osd_overlay.v",
            "display/osd_font_rom.v",
            "SD/video_timing_data.v",
            "SD/color_bar.v",
            "SD/video_delay.v",
        ],
        "incdir": ["SD"],
    },
    "tb_commit_read_index": {
        "sources": [
            "board/tests/tb_commit_read_index.v",
            "SD/video_timing_data.v",
            "SD/color_bar.v",
            "SD/four_bank_frame_commit.v",
            "SD/frame_fifo_read.v",
        ],
        "incdir": ["SD"],
    },
    "tb_video_effect": {
        "sources": ["board/tests/tb_video_effect.v", "display/video_effect.v"],
        "incdir": [],
    },
    "tb_key_event": {
        "sources": ["board/tests/tb_key_event.v", "display/key_event.v"],
        "incdir": [],
    },
    "tb_menu_control": {
        "sources": [
            "board/tests/tb_menu_control.v",
            "display/menu_control.v",
            "display/key_event.v",
        ],
        "incdir": [],
    },
    "tb_menu_cjk_rom": {
        "sources": ["board/tests/tb_menu_cjk_rom.v", "display/menu_cjk_rom.v"],
        "incdir": [],
    },
    "tb_soldout_overlay": {
        "sources": [
            "board/tests/tb_soldout_overlay.v",
            "display/soldout_overlay.v",
            "display/menu_cjk_rom.v",
            "display/menu_band_font.v",
        ],
        "incdir": ["include"],
    },
    "tb_menu_pipeline": {
        "sources": [
            "board/tests/tb_menu_pipeline.v",
            "display/soldout_overlay.v",
            "display/menu_cjk_rom.v",
            "display/menu_band_font.v",
            "display/video_effect.v",
            "display/osd_overlay.v",
            "display/osd_font_rom.v",
            "SD/video_timing_data.v",
            "SD/video_delay.v",
            "SD/color_bar.v",
        ],
        "incdir": ["include", "SD"],
    },
    "tb_video_transition": {
        "sources": [
            "board/tests/tb_video_transition.v",
            "display/video_transition.v",
            "SD/four_bank_frame_commit.v",
        ],
        "incdir": [],
    },
    "tb_transition_pipeline": {
        "sources": [
            "board/tests/tb_transition_pipeline.v",
            "display/video_effect.v",
            "display/video_transition.v",
            "display/osd_overlay.v",
            "display/osd_font_rom.v",
            "SD/video_timing_data.v",
            "SD/video_delay.v",
            "SD/color_bar.v",
            "SD/four_bank_frame_commit.v",
        ],
        "incdir": ["SD"],
    },
    "tb_media_follow_bank": {
        "sources": [
            "board/tests/tb_media_follow_bank.v",
            "state_code_media_cdc.v",
        ],
        "incdir": [],
    },
    "tb_top_wiring": {
        "sources": [
            "board/tests/tb_top_wiring.v",
            "top_tf_hdmi_audio.v",
            "display/video_effect.v",
            "display/video_transition.v",
            "display/osd_overlay.v",
            "display/osd_status_cdc.v",
            "display/osd_font_rom.v",
            "display/menu_control.v",
            "display/key_event.v",
            "display/soldout_overlay.v",
            "display/menu_cjk_rom.v",
            "display/menu_band_font.v",
            "board/hx4s20_board_top.v",
            "SD/sd_card_bmp.v",
            "SD/fat32_bmp_engine.v",
            "SD/fat32_volume_scanner.v",
            "SD/fat32_file_streamer.v",
            "SD/sd_sector_adapter.v",
            "SD/fat32_bmp_parser.v",
            "SD/sd_card_top.v",
            "SD/sd_card_cmd.v",
            "SD/sd_card_sec_read_write.v",
            "SD/spi_master.v",
            "SD/frame_read_write.v",
            "SD/frame_fifo_read.v",
            "SD/frame_fifo_write.v",
            "IP/afifo_16_32_256.v",
            "IP/afifo_32_16_256.v",
            "SD/seg_decoder.v",
            "SD/seg_scan.v",
            "SD/video_timing_data.v",
            "SD/video_delay.v",
            "SD/color_bar.v",
            "SD/four_bank_frame_commit.v",
            "state_code_media_cdc.v",
            "pcm_test_tone.v",
            "pcm_media_tone.v",
            "audio_arc_calculate.v",
            "media_hdmi_audio_bridge.v",
            "startup_pulse.v",
            "video_rgb_to_axis_640x480.v",
        ],
        "incdir": ["SD", "include"],
    },
}


def run_one(top: str, cfg: dict) -> bool:
    WORK_ROOT.mkdir(parents=True, exist_ok=True)
    run_dir = WORK_ROOT / top
    if run_dir.exists():
        shutil.rmtree(run_dir, ignore_errors=True)
    run_dir.mkdir(parents=True, exist_ok=True)
    vlib = MS / "vlib.exe"
    vlog = MS / "vlog.exe"
    vsim = MS / "vsim.exe"

    subprocess.run([str(vlib), "work"], cwd=run_dir, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    args = [str(vlog), "-sv", "-work", "work"]
    for d in cfg["incdir"]:
        args.append("+incdir+" + str(BASE / d))
    args += [str(BASE / s) for s in cfg["sources"]]
    comp = subprocess.run(args, cwd=run_dir, capture_output=True, text=True)
    (run_dir / "vlog.log").write_text(comp.stdout + comp.stderr, encoding="utf-8")
    if comp.returncode != 0:
        print(f"FAIL {top}: vlog exit {comp.returncode}")
        print(comp.stdout[-4000:])
        return False

    sim = subprocess.run(
        [str(vsim), "-c", "-quiet", "-do", "run -all; quit -f", "work." + top],
        cwd=run_dir, capture_output=True, text=True,
    )
    text = sim.stdout + sim.stderr
    (run_dir / "vsim.log").write_text(text, encoding="utf-8")
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    (LOG_DIR / f"modelsim_{top}.log").write_text(text, encoding="utf-8")

    ok = True
    reasons = []
    if sim.returncode != 0:
        ok = False
        reasons.append(f"vsim exit {sim.returncode}")
    if re.search(r"\*\* (Fatal|Error):", text):
        ok = False
        reasons.append("fatal/error marker")
    if not re.search(r"Errors: 0, Warnings: \d+", text):
        ok = False
        reasons.append("no clean Errors: 0 summary")
    if "PASS" not in text:
        ok = False
        reasons.append("no PASS marker")

    status = "PASS" if ok else "FAIL"
    detail = "" if ok else " (" + ", ".join(reasons) + ")"
    marker = next((ln.strip() for ln in text.splitlines() if "PASS" in ln or "FAIL" in ln), "")
    print(f"{status} {top}{detail}  {marker}")
    if not ok:
        print(text[-4000:])
    return ok


def main() -> int:
    if not MS.is_dir():
        print(f"ModelSim not found at {MS}")
        return 2
    names = sys.argv[1:] or list(TESTS)
    results = [run_one(n, TESTS[n]) for n in names]
    print(f"ModelSim OSD summary: {sum(results)}/{len(results)} passed")
    return 0 if all(results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
