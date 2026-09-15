#!/usr/bin/env python3
"""Run span regression in real offscreen LÖVE."""
import os, subprocess, tempfile
from pathlib import Path
root=Path(__file__).resolve().parents[1]
app=Path(tempfile.mkdtemp(prefix="span-check-"))
for asset in root.iterdir():
    if asset.name!='main.lua' and asset.suffix in {'.lua','.glsl','.ttf'}:(app/asset.name).symlink_to(asset)
(app/'legacy.glsl').symlink_to(root/'tools/baselines/heightfield.glsl')
source=(root/'main.lua').read_text().replace('VIEW_DIST        = 556.0','VIEW_DIST        = 128.0')
(app/'main.lua').write_text(source.replace('caves=CONFIG.CAVES','caves=false')+'\n'+(root/'tools/check_spans.lua').read_text())
out=root/'artifacts/part3';out.mkdir(exist_ok=True)
r=subprocess.run(['love',str(app)],capture_output=True,text=True,timeout=120,env={**os.environ,'SDL_VIDEODRIVER':'offscreen','ALSOFT_DRIVERS':'null','SPAN_OUTPUT':str(out)})
print(r.stdout,end='');print(r.stderr,end='');(out/'span-checks.txt').write_text(r.stdout+r.stderr)
raise SystemExit(r.returncode)
