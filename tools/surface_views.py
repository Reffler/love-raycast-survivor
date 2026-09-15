#!/usr/bin/env python3
"""Capture actual LÖVE flying views at surveyed points; requires Pillow for contact sheet."""
import argparse,json,os,subprocess,tempfile
from pathlib import Path
from PIL import Image,ImageDraw
root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output',type=Path,default=root/'artifacts/surface-v2')
args=parser.parse_args();folder=args.output.resolve()
survey=json.loads((folder/'survey.json').read_text())
cases=[]
for result in survey:
    for name in ['peak','coast','river']:
        if name in result['points']:
            x,y,z=result['points'][name];cases.append(f'{{{result["seed"]},"{name}",{x},{y},{z}}}')
app=Path(tempfile.mkdtemp(prefix='surface-views-'))
for p in root.iterdir():
    if p.name!='main.lua' and p.suffix in {'.lua','.glsl','.ttf'}:(app/p.name).symlink_to(p)
source=(root/'main.lua').read_text().replace('VIEW_DIST        = 256.0','VIEW_DIST        = 768.0')
harness=r'''
local originalLoad=love.load
function love.load()
  originalLoad();love.window.setMode(960,540,{fullscreen=false,vsync=0});love.resize(love.graphics.getDimensions())
  CONFIG.DEBUG_ENABLED=false
  local cases=CASES
  for _,c in ipairs(cases) do
    if world.seed~=c[1] then
      world.texture:release();world.imageData:release();world.tile:release();world.maxTexture:release();world.maxData:release();world.maxTile:release()
      world=World.new(c[1],CONFIG.VIEW_DIST);world:initGraphics(c[3],c[4])
      raycastShader:send('heightTex',world.texture);raycastShader:send('chunkMaxTex',world.maxTexture)
      raycastShader:send('cacheSize',world.size);raycastShader:send('maxHeight',world.maxHeight)
      collectgarbage('collect')
    end
    px,py=c[3]-150,c[4]-150;rot=math.pi/4;pitch=math.rad(-30);eyeHeight=c[5]+130
    if c[2]=='coast' then
      local G=require('geography')
      local dx=G.height(world.terrain.settings,c[3]+64,c[4])-G.height(world.terrain.settings,c[3]-64,c[4])
      local dy=G.height(world.terrain.settings,c[3],c[4]+64)-G.height(world.terrain.settings,c[3],c[4]-64)
      rot=math.atan2(dy,dx);px,py=c[3]-math.cos(rot)*180,c[4]-math.sin(rot)*180
      eyeHeight=world.terrain.settings.SEA_LEVEL+110;pitch=math.rad(-25)
    end
    world:request(px,py);while world:hasPending() do world:step(256,world.upload) end
    previousPx,previousPy,previousEyeHeight=px,py,eyeHeight;physicsAccumulator=0
    eyeStepOffset,previousEyeStepOffset=0,0;lastRot,lastPitch=nil,nil
    love.draw()
    local data=renderCanvas:newImageData();local png=data:encode('png')
    local name=('view-%d-%s.png'):format(c[1],c[2])
    local f=assert(io.open(os.getenv('SURFACE_OUTPUT')..'/'..name,'wb'));f:write(png:getString());f:close()
    data:release();png:release();print(name)
  end
end
function love.run()
  local ok,message=pcall(love.load);if not ok then print(message) end
  return function() return ok and 0 or 1 end
end
'''.replace('CASES','{'+','.join(cases)+'}')
(app/'main.lua').write_text(source+'\n'+harness)
result=subprocess.run(['love',str(app)],capture_output=True,text=True,timeout=120,
    env={**os.environ,'SDL_VIDEODRIVER':'offscreen','ALSOFT_DRIVERS':'null','SURFACE_OUTPUT':str(folder)})
print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
contact=Image.new('RGB',(1440,894),'#17212b');d=ImageDraw.Draw(contact)
for row,result in enumerate(survey):
    for col,name in enumerate(['peak','coast','river']):
        path=folder/f'view-{result["seed"]}-{name}.png'
        if path.exists():
            contact.paste(Image.open(path).resize((480,270)),(col*480,row*298+28))
            d.text((col*480+10,row*298+8),f'Seed {result["seed"]} / {name} / flight view',fill='white')
contact.save(folder/'flight-views.png')
