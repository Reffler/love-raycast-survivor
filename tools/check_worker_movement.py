#!/usr/bin/env python3
"""Exercise production physics/worker path at real sprint speed and compare GPU uploads."""
import os
from pathlib import Path
import subprocess
import tempfile
root=Path(__file__).resolve().parents[1]
app=Path(tempfile.mkdtemp(prefix='raycast-worker-movement-'))
for asset in root.iterdir():
    if asset.name!='main.lua' and asset.suffix in {'.lua','.glsl','.ttf'}:(app/asset.name).symlink_to(asset)
(app/'main.lua').write_text((root/'main.lua').read_text()+'\n'+(root/'tools/check_worker_movement.lua').read_text())
r=subprocess.run(['love',str(app)],capture_output=True,text=True,timeout=60,
    env={**os.environ,'SDL_VIDEODRIVER':'offscreen','ALSOFT_DRIVERS':'null'})
print(r.stdout,end='');print(r.stderr,end='');raise SystemExit(r.returncode)
