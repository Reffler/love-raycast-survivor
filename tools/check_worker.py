#!/usr/bin/env python3
"""Run actual worker, cancellation, residency and GPU parity checks."""
import os
from pathlib import Path
import subprocess
import tempfile
root=Path(__file__).resolve().parents[1]
app=Path(tempfile.mkdtemp(prefix='raycast-worker-check-'))
for asset in root.iterdir():
    if asset.name!='main.lua' and asset.suffix in {'.lua','.glsl','.ttf'}:
        (app/asset.name).symlink_to(asset)
(app/'main.lua').write_text((root/'main.lua').read_text()+'\n'+(root/'tools/check_worker.lua').read_text())
result=subprocess.run(['love',str(app)],capture_output=True,text=True,timeout=120,
    env={**os.environ,'SDL_VIDEODRIVER':'offscreen','ALSOFT_DRIVERS':'null'})
print(result.stdout,end='');print(result.stderr,end='')
raise SystemExit(result.returncode)
