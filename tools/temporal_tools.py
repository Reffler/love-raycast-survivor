#!/usr/bin/env python3
"""GPU temporal AA validation and matched archived 4x comparison."""
import argparse, os, subprocess, tempfile
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('mode',choices=['check','profile'])
p.add_argument('--output',type=Path,default=Path('artifacts/temporal-aa'))
p.add_argument('--renderer',choices=['msaa4','taa'],help='Profile only one renderer')
a=p.parse_args();root=Path(__file__).resolve().parents[1]
for mode in ([a.renderer] if a.renderer else ['msaa4','taa'] if a.mode=='profile' else ['taa']):
    app=Path(tempfile.mkdtemp(prefix='raycast-temporal-'))
    for asset in root.iterdir():
        if asset.name not in {'main.lua','raycast.glsl'} and (asset.suffix in {'.lua','.glsl','.ttf'} or asset.name=='textures'):
            (app/asset.name).symlink_to(asset)
    source=root/'artifacts/temporal-aa/msaa4' if mode=='msaa4' else root
    (app/'raycast.glsl').symlink_to(source/'raycast.glsl')
    (app/'main.lua').write_text('function love.errorhandler(e) print(e);return function() return 1 end end\n'+(source/'main.lua').read_text()+'\n'+(root/'tools'/('temporal_'+a.mode+'.lua')).read_text())
    out=a.output.resolve()/mode;out.mkdir(parents=True,exist_ok=True)
    # Catch syntax errors before LÖVE starts its graphical error loop.
    subprocess.run(['luajit','-b',str(app/'main.lua'),str(app/'check.luac')],check=True)
    result=subprocess.run(['love',str(app)],capture_output=True,text=True,timeout=180,env={**os.environ,'SDL_VIDEODRIVER':'offscreen','ALSOFT_DRIVERS':'null','TAA_OUTPUT':str(out)})
    print(mode+':\n'+result.stdout+result.stderr,flush=True)
    (out/(a.mode+'.txt')).write_text(result.stdout+result.stderr)
    result.check_returncode()
