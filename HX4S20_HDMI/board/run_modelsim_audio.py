from datetime import datetime
import argparse
from pathlib import Path
import json
import re
import subprocess
import tempfile


PROJECT = Path(__file__).resolve().parent.parent
MODELSIM = Path(r"D:\altera\14.1\modelsim_ase\win32aloem")
RUN_ROOT = None
TESTS = {
    "tb_audio_pcm": [
        "board/tests/tb_audio_pcm.v", "pcm_test_tone.v", "audio_arc_calculate.v"
    ],
    "tb_audio_media_pcm": [
        "board/tests/tb_audio_media_pcm.v", "pcm_media_tone.v", "media_hdmi_audio_bridge.v"
    ],
    "tb_audio_media_cdc": [
        "board/tests/tb_audio_media_cdc.v", "state_code_media_cdc.v"
    ],
    "tb_media_follow_bank": [
        "board/tests/tb_media_follow_bank.v", "state_code_media_cdc.v"
    ],
    "tb_audio": [
        "board/tests/tb_audio.v", "hdmi_audio_tone_i2s_64fs.v", "I2S_receiver.v"
    ],
    "tb_pcm_ring_buffer": [
        "board/tests/tb_pcm_ring_buffer.v", "audio/pcm_ring_buffer.v"
    ],
    "tb_pcm_stream_player": [
        "board/tests/tb_pcm_stream_player.v", "audio/pcm_stream_player.v",
        "audio/pcm_ring_buffer.v", "SD/fat32_file_streamer.v"
    ],
    "tb_audio_source_mux": [
        "board/tests/tb_audio_source_mux.v", "audio/audio_source_mux.v"
    ],
    "tb_audio_page_gate": [
        "board/tests/tb_audio_page_gate.v", "audio/audio_page_gate.v"
    ],
    "tb_audio_waveform": [
        "board/tests/tb_audio_waveform.v", "display/audio_waveform_overlay.v"
    ],
    "tb_pcm_abort_timing": [
        "board/tests/tb_pcm_abort_timing.v", "audio/pcm_stream_player.v",
        "audio/pcm_ring_buffer.v", "SD/fat32_file_streamer.v"
    ],
    "tb_audio_repeat_switch": [
        "board/tests/tb_audio_repeat_switch.v", "audio/audio_page_gate.v",
        "audio/pcm_stream_player.v", "audio/pcm_ring_buffer.v",
        "audio/audio_source_mux.v", "SD/fat32_file_streamer.v"
    ],
    "tb_audio_subsystem": [
        "board/tests/tb_audio_subsystem.v", "audio/audio_page_gate.v",
        "audio/pcm_stream_player.v", "audio/pcm_ring_buffer.v",
        "audio/audio_source_mux.v", "SD/fat32_file_streamer.v"
    ],
}


def execute(args, cwd, log_path):
    result = subprocess.run(args, cwd=cwd, text=True, capture_output=True)
    text = result.stdout + result.stderr
    log_path.write_text(text, encoding="utf-8", errors="replace")
    return result.returncode, text


def run_test(top, sources):
    workdir = RUN_ROOT / top
    workdir.mkdir()
    vlib_log = workdir / "vlib.log"
    vlog_log = workdir / "vlog.log"
    vsim_log = workdir / "vsim.log"

    rc, output = execute([str(MODELSIM / "vlib.exe"), "work"], workdir, vlib_log)
    if rc != 0:
        raise RuntimeError(f"{top}: vlib exit={rc}; see {vlib_log}")

    vlog_args = [str(MODELSIM / "vlog.exe"), "-sv", "-work", "work"]
    vlog_args.extend(str(PROJECT / source) for source in sources)
    rc, output = execute(vlog_args, workdir, vlog_log)
    if rc != 0:
        raise RuntimeError(f"{top}: vlog exit={rc}; see {vlog_log}")

    rc, output = execute(
        [str(MODELSIM / "vsim.exe"), "-c", "-quiet", "-do", "run -all; quit -f", f"work.{top}"],
        workdir,
        vsim_log,
    )
    if rc != 0:
        raise RuntimeError(f"{top}: vsim exit={rc}; see {vsim_log}")
    if re.search(r"\*\* (?:Fatal|Error):", output, re.IGNORECASE):
        raise RuntimeError(f"{top}: simulator reported Fatal/Error; see {vsim_log}")
    if not re.search(r"Errors:\s*0,\s*Warnings:\s*\d+", output):
        raise RuntimeError(f"{top}: missing clean Errors: 0 summary; see {vsim_log}")
    if "PASS" not in output:
        raise RuntimeError(f"{top}: missing PASS marker; see {vsim_log}")
    if re.search(r"^FAIL\b", output, re.MULTILINE):
        raise RuntimeError(f"{top}: testbench reported FAIL; see {vsim_log}")
    print(f"PASS {top}: {vsim_log}")
    return {"test": top, "status": "PASS", "workdir": str(workdir),
            "vlib_log": str(vlib_log), "vlog_log": str(vlog_log), "vsim_log": str(vsim_log)}


def main():
    global RUN_ROOT
    parser = argparse.ArgumentParser(description="Run the focused HDMI audio ModelSim regression.")
    parser.add_argument(
        "--log-dir", type=Path,
        help="save logs in this new or empty directory instead of a temporary directory",
    )
    args = parser.parse_args()
    RUN_ROOT = args.log_dir if args.log_dir else Path(tempfile.mkdtemp(prefix="modelsim_audio_"))
    if args.log_dir:
        if RUN_ROOT.exists() and any(RUN_ROOT.iterdir()):
            raise RuntimeError(f"log directory is not empty: {RUN_ROOT}")
        RUN_ROOT.mkdir(parents=True, exist_ok=True)

    version_path = RUN_ROOT / "version.log"
    rc, version = execute([str(MODELSIM / "vsim.exe"), "-version"], RUN_ROOT, version_path)
    if rc != 0:
        raise RuntimeError(f"ModelSim version query failed ({rc}); see {version_path}")
    print(version.strip())

    results = [run_test(top, files) for top, files in TESTS.items()]
    summary = {
        "created": datetime.now().astimezone().isoformat(timespec="seconds"),
        "modelsim": version.strip(),
        "results": results,
    }
    summary_path = RUN_ROOT / "results.json"
    summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"PASS ModelSim audio regression ({len(results)} tests)")
    print(f"LOGDIR {RUN_ROOT}")
    print(f"SUMMARY {summary_path}")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"ERROR {exc}")
        print(f"LOGDIR {RUN_ROOT}")
        raise SystemExit(1)
