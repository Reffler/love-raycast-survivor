#!/usr/bin/env python3
"""Reproducible random-seed aerial surveys. Requires Pillow for PNG/contact sheets."""
from pathlib import Path
import subprocess,random,json,argparse
from PIL import Image,ImageDraw
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output',type=Path,default=Path('artifacts/surface-v2'))
args=parser.parse_args();folder=args.output;folder.mkdir(parents=True,exist_ok=True)
rng=random.Random(20260912);seeds=[rng.randrange(1,1000000) for _ in range(3)]
results=[]
for seed in seeds:
    points={};metrics=''
    for name,detail in [('',1.25),('-no-detail',0)]:
        p=folder/f'seed-{seed}{name}.ppm'
        run=subprocess.run(['luajit','tools/surface_atlas.lua',str(seed),str(p),str(detail)],capture_output=True,text=True,check=True)
        Image.open(p).save(p.with_suffix('.png'));p.unlink()
        if not name:
            metrics=run.stdout;print(seed,metrics,flush=True)
            for line in metrics.splitlines():
                if line.startswith('POINT,'):
                    _,key,x,y,z=line.split(',');points[key]=[int(x),int(y),int(z)]
    results.append({'seed':seed,'points':points,'metrics':metrics})
(folder/'survey.json').write_text(json.dumps(results,indent=2))
contact=Image.new('RGB',(1536,1096),'#17212b');draw=ImageDraw.Draw(contact)
for i,result in enumerate(results):
    for j,name in enumerate(['','-no-detail']):
        contact.paste(Image.open(folder/f'seed-{result["seed"]}{name}.png'),(i*512,j*548+36))
        draw.text((i*512+12,j*548+10),f'Seed {result["seed"]} | 4096 blocks | '+('no detail' if j else 'full terrain'),fill='white')
contact.save(folder/'atlas.png')
