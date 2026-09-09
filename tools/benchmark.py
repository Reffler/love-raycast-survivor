#!/usr/bin/env python3
"""Measure warmed render throughput and compare pixels against previous main.lua.

Offscreen timing excludes desktop presentation and normal frame-loop sleeps.
Requires Python 3 and LÖVE. Assets always come from current project.
"""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline', type=Path, help='previous main.lua to compare')
parser.add_argument('--output', type=Path, help='artifact directory (default: temporary)')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
work = args.output.resolve() if args.output else Path(tempfile.mkdtemp(prefix='raycast-benchmark-'))
work.mkdir(parents=True, exist_ok=True)
harness = Path(__file__).with_suffix('.lua').read_text()


def run(source, name):
    app = work / name
    app.mkdir(exist_ok=True)
    for asset in ['levels.lua', 'dirt.png', 'grass.png', 'skybox']:
        target = app / asset
        if not target.exists():
            target.symlink_to(root / asset)
    (app / 'main.lua').write_text(source.read_text() + '\n' + harness)
    print(f'{name}: {source}', flush=True)
    result = subprocess.run(
        ['love', str(app)], capture_output=True, text=True, timeout=120,
        env={**os.environ, 'SDL_VIDEODRIVER': 'offscreen', 'ALSOFT_DRIVERS': 'null',
             'RAYCAST_OUTPUT': str(app),
             'RAYCAST_REFERENCE': str(work / 'before') if name == 'after' and args.baseline else ''},
    )
    print(result.stdout, end='')
    if result.stderr:
        print(result.stderr, file=sys.stderr)
    (app / 'timings.txt').write_text(result.stdout)
    result.check_returncode()


if args.baseline:
    run(args.baseline.resolve(), 'before')
run(root / 'main.lua', 'after')
print(f'Artifacts: {work}')
