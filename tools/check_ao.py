#!/usr/bin/env python3
"""Check voxel AO on all six face orientations using actual LÖVE shaders."""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
app = Path(tempfile.mkdtemp(prefix="raycast-ao-"))
(app / "raycast.glsl").symlink_to(root / "raycast.glsl")
(app / "main.lua").write_text(r'''function love.load()
  local source=love.filesystem.read('raycast.glsl')
  local prefix=source:sub(1,assert(source:find('vec4 effect(',1,true))-1)
  local shader=love.graphics.newShader(prefix..[[
    extern vec3 hit;extern vec3 normal;
    vec4 effect(vec4 c,Image t,vec2 tc,vec2 sc) {
      return vec4(ambientOcclusion(hit,normal),solidAt(vec3(3,3,2)),solidAt(vec3(3,3,3)),1);
    }
  ]])
  local heights=love.image.newImageData(8,8,'rgba32f')
  local maxima=love.image.newImageData(1,1,'rgba32f');maxima:setPixel(0,0,520,0,0,1)
  local target=love.graphics.newCanvas(1,1,{format='rgba32f'})
  shader:send('cacheSize',8);shader:send('cacheOffset',{0,0})
  shader:send('chunkMaxTex',love.graphics.newImage(maxima))
  local function add(a,b,s) return {a[1]+b[1]*s,a[2]+b[2]*s,a[3]+b[3]*s} end
  for _,n in ipairs({{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}}) do
    local u=n[1]~=0 and {0,1,0} or {1,0,0}
    local v=n[3]~=0 and {0,1,0} or {0,0,1}
    local hit=add({3.5,3.5,3.5},n,0.5)
    local outside=add({3,3,3},n,1)
    for count=0,2 do
      local spans=love.image.newImageData(8,8,'rgba32f')
      local empty=love.image.newImageData(8,8,'rgba32f')
      for y=0,7 do for x=0,7 do
        heights:setPixel(x,y,64,0,0,1)
        spans:setPixel(x,y,-1,-1,-1,-1);empty:setPixel(x,y,-1,-1,-1,-1)
      end end
      spans:setPixel(3,3,3,4,-1,-1)
      for i=1,count do
        local b=add(outside,i==1 and u or v,-1)
        spans:setPixel(b[1],b[2],b[3],b[3]+1,-1,-1)
      end
      shader:send('heightTex',love.graphics.newImage(heights))
      shader:send('spanTex0',love.graphics.newImage(spans))
      shader:send('spanTex1',love.graphics.newImage(empty))
      shader:send('hit',hit);shader:send('normal',n)
      love.graphics.setCanvas(target);love.graphics.setShader(shader)
      love.graphics.setBlendMode('replace');love.graphics.rectangle('fill',0,0,1,1)
      love.graphics.setShader();love.graphics.setCanvas()
      local data=target:newImageData();local ao,air,solid=data:getPixel(0,0)
      local expected=({1,1-0.55/6,(0.45+2*(1-0.55/3)+1)/4})[count+1]
      assert(math.abs(ao-expected)<0.00001,('AO %s expected %s'):format(ao,expected))
      assert(air==0 and solid==1,'Cavity occupancy incorrect')
      data:release()
    end
  end
  print('PASS: exposed faces, edge shadows, enclosed corners, cavity occupancy; all six normals')
end
function love.run()
  local ok,err=pcall(love.load)
  if not ok then print(err) end
  return function() return ok and 0 or 1 end
end
''')
result = subprocess.run(["love", str(app)], capture_output=True, text=True, timeout=60,
    env={**os.environ, "SDL_VIDEODRIVER": "offscreen", "ALSOFT_DRIVERS": "null"})
print(result.stdout, end="")
print(result.stderr, end="")
raise SystemExit(result.returncode)
