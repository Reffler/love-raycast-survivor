#!/usr/bin/env python3
"""Run actual GPU shadow validation or five-view profiling in an isolated LÖVE app."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('mode',choices=['check','profile'])
p.add_argument('--output',type=Path,default=Path('artifacts/pixel-shadows'))
args=p.parse_args()
root=Path(__file__).resolve().parents[1]
app=Path(tempfile.mkdtemp(prefix='raycast-shadows-'))
for asset in root.iterdir():
    if asset.name!='main.lua' and (asset.suffix in {'.lua','.glsl','.ttf'} or asset.name=='textures'):
        (app/asset.name).symlink_to(asset)
(app/'before.glsl').symlink_to(root/'artifacts/pixel-shadows/before/raycast.glsl')
(app/'main.lua').write_text((root/'main.lua').read_text()+'\n'+(root/'tools'/('shadow_'+args.mode+'.lua')).read_text())
args.output.mkdir(parents=True,exist_ok=True)
r=subprocess.run(['love',str(app)],capture_output=True,text=True,timeout=180,
    env={**os.environ,'SDL_VIDEODRIVER':'offscreen','ALSOFT_DRIVERS':'null','SHADOW_OUTPUT':str(args.output.resolve())})
print(r.stdout,end='');print(r.stderr,end='')
(args.output/(args.mode+'.txt')).write_text(r.stdout+r.stderr)
raise SystemExit(r.returncode)
