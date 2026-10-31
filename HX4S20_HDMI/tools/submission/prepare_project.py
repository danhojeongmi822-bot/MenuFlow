#!/usr/bin/env python3
"""Set the TD Project Path to the location of this cloned project."""
import argparse
from pathlib import Path
import re

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--portable', action='store_true', help='Restore the repository placeholder before committing')
args = parser.parse_args()
project = Path(__file__).resolve().parents[2]
path = project / 'HX4S20_HDMI_Config.al'
data = path.read_bytes()
project_path = '.' if args.portable else project.as_posix()
new, count = re.subn(rb'(<Project\b[^>]*\bPath=")[^"]*(")',
                     lambda match: match[1] + project_path.encode('utf-8') + match[2],
                     data, count=1)
assert count == 1, 'Could not locate the TD Project Path'
path.write_bytes(new)
print('TD Project Path: ' + project_path)
print('Only the machine-local Project Path was updated; HDL/IP/constraints were not changed.')
