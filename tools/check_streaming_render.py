#!/usr/bin/env python3
"""Compare moving, streamed GPU frames with fully loaded terrain at full view distance."""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
app = Path(tempfile.mkdtemp(prefix='raycast-streaming-'))
for asset in root.iterdir():
    if asset.name != 'main.lua' and asset.suffix in {'.lua', '.glsl', '.ttf'}:
        (app / asset.name).symlink_to(asset)
harness = r'''
local originalLoad=love.load
function love.load()
  originalLoad();CONFIG.DEBUG_ENABLED=false
  love.window.setMode(640,360,{fullscreen=false,vsync=0});love.resize(love.graphics.getDimensions())
  local maxUpdate=0
  for frame=1,270 do
    px,py=3.5+frame*50/60,3.5
    local start=love.timer.getTime();world:update(px,py)
    maxUpdate=math.max(maxUpdate,love.timer.getTime()-start)
    if frame%90==0 then
      eyeHeight=world:height(math.floor(px),math.floor(py))+20
      previousPx,previousPy,previousEyeHeight=px,py,eyeHeight
      eyeStepOffset,previousEyeStepOffset,physicsAccumulator=0,0,0
      pitch=math.rad(-10)
      local frames={}
      for i=1,4 do
        rot=(i-1)*math.pi/2;love.draw()
        local data=renderCanvas:newImageData();frames[i]=data:getString();data:release()
      end
      while world:hasPending() do world:step(256,world.upload) end
      for i=1,4 do
        rot=(i-1)*math.pi/2;love.draw()
        local data=renderCanvas:newImageData()
        assert(data:getString()==frames[i],('Streaming changed visible pixels at frame %d, heading %d'):format(frame,i))
        if frame==270 and i==1 then
          local file=assert(io.open(os.getenv('RAYCAST_OUTPUT')..'/sprint.png','wb'))
          file:write(data:encode('png'):getString());file:close()
        end
        data:release()
      end
    end
  end
  print(('PASS: 12 streamed GPU views equal fully loaded frames, 50 blocks/sec, 556-block view; max update %.3f ms'):format(maxUpdate*1000))
end
function love.run()
  local ok,err=pcall(love.load);if not ok then print(err) end
  return function() return ok and 0 or 1 end
end
'''
(app / 'main.lua').write_text((root / 'main.lua').read_text() + harness)
result = subprocess.run(['love', str(app)], capture_output=True, text=True, timeout=120,
    env={**os.environ, 'SDL_VIDEODRIVER': 'offscreen', 'ALSOFT_DRIVERS': 'null', 'RAYCAST_OUTPUT': str(app)})
print(result.stdout, end='')
print(result.stderr, end='')
print(f'Artifacts: {app}')
raise SystemExit(result.returncode)
