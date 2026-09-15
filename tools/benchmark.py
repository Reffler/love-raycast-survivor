#!/usr/bin/env python3
"""Measure terrain rendering and streaming across chunk boundaries.

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
parser.add_argument('--output', type=Path, help='artifact directory (default: temporary)')
parser.add_argument('--shader', type=Path, help='optional reference shader for same-world comparisons')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
work = args.output.resolve() if args.output else Path(tempfile.mkdtemp(prefix='raycast-benchmark-'))
work.mkdir(parents=True, exist_ok=True)
harness = Path(__file__).with_suffix('.lua').read_text()


def run(source, name):
    app = work / name
    app.mkdir(exist_ok=True)
    for asset in root.iterdir():
        if asset.name != 'main.lua' and asset.suffix in {'.lua', '.glsl', '.ttf'}:
            target = app / asset.name
            if not target.exists():
                target.symlink_to(asset)
    (app / 'main.lua').write_text('function love.errorhandler(message) print(message); return function() return 1 end end\n' + source.read_text() + '\n' + harness)
    if args.shader:
        shader = app / 'raycast.glsl'
        shader.unlink(missing_ok=True)
        shader.write_text(args.shader.read_text())
    print(f'{name}: {source}', flush=True)
    result = subprocess.run(
        ['love', str(app)], capture_output=True, text=True, timeout=120,
        env={**os.environ, 'SDL_VIDEODRIVER': 'offscreen', 'ALSOFT_DRIVERS': 'null',
             'RAYCAST_OUTPUT': str(app)},
    )
    print(result.stdout, end='')
    if result.stderr:
        print(result.stderr, file=sys.stderr)
    (app / 'timings.txt').write_text(result.stdout)
    result.check_returncode()


run(root / 'main.lua', 'after')
print(f'Artifacts: {work}')
