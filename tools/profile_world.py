#!/usr/bin/env python3
"""Profile generation, streaming, uploads and memory with a selected world module."""
import argparse, os, subprocess, tempfile
from pathlib import Path
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--distance',type=int,default=256)
parser.add_argument('--world',type=Path,default=Path('world.lua'))
parser.add_argument('--format',choices=['r16f','r32f'],default='r16f')
parser.add_argument('--output',type=Path)
parser.add_argument('--stage',default='full',choices=['geography','mountains','rivers','full'])
parser.add_argument('--terrain',type=Path)
parser.add_argument('--sources',type=Path,help='saved Lua modules for reproducible generation baseline')
args=parser.parse_args()
root=Path(__file__).resolve().parents[1]
app=Path(tempfile.mkdtemp(prefix='terrain-profile-'))
for asset in root.glob('*.lua'):
    if asset.name not in {'main.lua','world.lua'}:(app/asset.name).symlink_to(asset)
(app/'world.lua').write_text(args.world.read_text())
if args.sources:
    for asset in args.sources.glob('*.lua'):
        target=app/asset.name
        target.unlink(missing_ok=True)
        target.write_text(asset.read_text())
if args.terrain:
    (app/'terrain.lua').unlink()
    (app/'terrain.lua').write_text(args.terrain.read_text())
(app/'main.lua').write_text((root/'tools/profile_world.lua').read_text())
result=subprocess.run(['love',str(app)],capture_output=True,text=True,timeout=120,
    env={**os.environ,'SDL_VIDEODRIVER':'offscreen','ALSOFT_DRIVERS':'null','HEIGHT_FORMAT':args.format,'TERRAIN_STAGE':args.stage,'VIEW_DISTANCE':str(args.distance)})
print(result.stdout,end='');print(result.stderr,end='')
if args.output:args.output.write_text(result.stdout)
raise SystemExit(result.returncode)
