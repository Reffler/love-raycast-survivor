#!/usr/bin/env python3
"""Paced 1080p sprint into cold regions; record frame tails and streaming stalls."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--sources',type=Path)
parser.add_argument('--output',type=Path,required=True)
parser.add_argument('--fps',type=int,default=120)
parser.add_argument('--seconds',type=int,default=12)
args=parser.parse_args()
root=Path(__file__).resolve().parents[1]
app=Path(tempfile.mkdtemp(prefix='raycast-stream-profile-'))
for asset in root.iterdir():
    if asset.name!='main.lua' and asset.suffix in {'.lua','.glsl','.ttf'}:
        (app/asset.name).symlink_to(asset)
source=(root/'main.lua').read_text()
if args.sources:
    for asset in args.sources.glob('*.lua'):
        if asset.name=='main.lua':source=asset.read_text()
        else:
            (app/asset.name).unlink(missing_ok=True);(app/asset.name).write_text(asset.read_text())
(app/'main.lua').write_text(source+'\n'+(root/'tools/profile_streaming.lua').read_text())
args.output.mkdir(parents=True,exist_ok=True)
result=subprocess.run(['love',str(app)],capture_output=True,text=True,timeout=120,
    env={**os.environ,'SDL_VIDEODRIVER':'offscreen','ALSOFT_DRIVERS':'null','STREAM_OUTPUT':str(args.output.resolve()),
         'STREAM_FPS':str(args.fps),'STREAM_SECONDS':str(args.seconds)})
print(result.stdout,end='');print(result.stderr,end='')
(args.output/'summary.txt').write_text(result.stdout+result.stderr)
raise SystemExit(result.returncode)
