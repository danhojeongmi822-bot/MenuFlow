from pathlib import Path
import hashlib
import json
import re
import xml.etree.ElementTree as ET

base = Path(__file__).resolve().parent.parent
project = ET.fromstring((base / 'HX4S20_HDMI_Config.al').read_text(encoding='utf-8').replace('UsedInP&R', 'UsedInP&amp;R'))
assert project.findtext('./HardWare/Device') == 'EG4S20BG256'
assert project.findtext('./TOP_MODULE/MODULE') == 'hx4s20_board_top'
files = [f.get('Path') for f in project.findall('./Source_Files/Verilog/File')]
assert 'SD/sdram.v' in files and 'IP/sdram.v' not in files
assert project.find('./Source_Files/ADC_FILE/File').get('Path') == 'constraints/hx4s20_hdmi_a.adc'
assert project.find('./Source_Files/SDC_FILE/File').get('Path') == 'constraints/hx4s20_clocks.sdc'
adc = (base / 'constraints/hx4s20_hdmi_a.adc').read_text()
assignments = re.findall(r'set_pin_assignment\s+\{\s*(\S+)\s*\}\s*\{\s*LOCATION\s*=\s*(\w+);\s*IOSTANDARD\s*=\s*(\w+);', adc)
assert len(assignments) == 31
assert len({a[0] for a in assignments}) == 31
assert len({a[1] for a in assignments}) == 31
manifest = json.loads((base.parent / '实验位流/manifest.json').read_text(encoding='utf-8'))
bit = base.parent / manifest['verification_bitstream']
area_report = base.parent / manifest['area_report']
timing_report = base.parent / manifest['timing_report']
assert bit.is_file() and bit.stat().st_size > 0
assert area_report.is_file() and timing_report.is_file()
assert sorted(p.name for p in bit.parent.glob('*.bit')) == [bit.name], \
    '正式下载目录必须只保留 TD 当前运行的唯一 .bit 文件'
expected_sha256 = manifest.get('sha256')
actual_sha256 = hashlib.sha256(bit.read_bytes()).hexdigest()
assert not expected_sha256 or actual_sha256 == expected_sha256, 'canonical bitstream SHA-256 mismatch'
report = area_report.read_text()
checked = []
for name, pin, standard in assignments:
    assert re.search(r'^\s*' + re.escape(name) + r'\s+(?:INPUT|OUTPUT|INOUT)\s+' + pin + r'\s+' + standard + r'\s', report, re.M), name
    checked.append({'signal': name, 'location': pin, 'standard': standard})
negative_pairs = {'HDMI_CLK_P(n)': 'J1', 'HDMI_D0_P(n)': 'F4', 'HDMI_D1_P(n)': 'E4', 'HDMI_D2_P(n)': 'D3'}
for name, pin in negative_pairs.items():
    assert re.search(r'^\s*' + re.escape(name) + r'\s+OUTPUT\s+' + pin + r'\s+LVDS33\s', report, re.M), name
assert len({a[1] for a in assignments} | set(negative_pairs.values())) == 35
status = timing_report.read_text().strip()
timing_values = {name: float(value) for name, value in re.findall(r'(SWNS|STNS|HWNS|HTNS):\s*(-?[\d.]+)ns', status)}
assert len(timing_values) == 4, 'Missing timing summary values'
reported_timing_passed = all(value >= 0 for value in timing_values.values())
result = {'device': 'EG4S20BG256', 'top_level_signals_checked': checked, 'automatic_negative_pins': negative_pairs, 'physical_user_pads': 35, 'bitstream': str(bit), 'bitstream_bytes': bit.stat().st_size, 'sha256': actual_sha256, 'timing_report': str(timing_report), 'area_report': str(area_report), 'timing_status': status, 'timing_signoff_passed': reported_timing_passed, 'board_test_performed': False}
result.update({'timing_metrics_ns': timing_values, 'reported_timing_checks_passed': reported_timing_passed, 'timing_signoff_passed': reported_timing_passed, 'signoff_limitations': 'Basic clock constraints only; complete IO/CDC review and new bitstream board acceptance pending.'})
(base / 'board/pin_verification.json').write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding='utf-8')
print('PASS: 31 assigned signals and 4 differential negative pins match routed IO report.')
print('Bitstream: ' + str(bit.stat().st_size) + ' bytes')
print('Reported timing checks: ' + ('PASS' if reported_timing_passed else 'FAIL') + '; full IO/CDC and board signoff pending.')
if not reported_timing_passed:
    raise SystemExit('FAIL: negative setup/hold timing margin; bitstream is not eligible for acceptance')
