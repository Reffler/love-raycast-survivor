local originalLoad=love.load
function love.load()
  CONFIG.AA_ENABLED=false -- Exact frame comparisons test geometry independently of temporal history.
  originalLoad();CONFIG.DEBUG_ENABLED=false
  local seed=tonumber(os.getenv('FLOW_SEED')) or 1337
  if world.seed~=seed then
    for _,name in ipairs({'texture','imageData','tile','maxTexture','maxData','maxTile'}) do world[name]:release() end
    world=World.new(seed,CONFIG.VIEW_DIST);world:initGraphics(0,0)
  end
  love.window.setMode(1920,1080,{fullscreen=false,vsync=0});love.resize(love.graphics.getDimensions())
  local drop
  for _,d in ipairs(world.terrain.regions:get(0,0).drops) do
    if d.x>0 and d.y>0 and (os.getenv('FLOW_SUPPORT_ONLY')~='1' or d.reachLower==d.upper and d.kind=='fall') then drop=d end
  end
  assert(drop,'Missing generated waterfall fixture')
  local d=drop;local angle=math.atan2(d.by-d.ay,d.bx-d.ax)
  print(('Generated seed %d outlet %d,%d: metadata %g/%g, surface %g/%g'):format(seed,d.x,d.y,d.upper,d.reachLower or d.lower,d.upper,d.lower))
  local sloped=raycastShader
  local source=assert(love.filesystem.read('raycast.glsl')):gsub('if %(water>height && fract','if (false && water>height && fract')
  local flat=love.graphics.newShader('#define MAX_DDA_STEPS '..MAX_DDA_STEPS..'\n'..source)
  local noSkipSource=assert(love.filesystem.read('raycast.glsl')):gsub('if %(min%(camPos.z','if (false && min(camPos.z')
  local noSkip=love.graphics.newShader('#define MAX_DDA_STEPS '..MAX_DDA_STEPS..'\n'..noSkipSource)
  local function shader(s)
    raycastShader=s;lastRot,lastPitch=nil,nil;updateProjection(love.graphics.getDimensions())
    s:send('heightTex',world.texture)
    if s:hasUniform('chunkMaxTex') then s:send('chunkMaxTex',world.maxTexture) end
    s:send('cacheSize',world.size);s:send('maxHeight',world.maxHeight);s:send('viewDist',CONFIG.VIEW_DIST)
  end
  for _,view in ipairs({{'fall',25,d.lower+14,0},{'landing',9,d.lower+9,-45},{'overview',42,d.upper+25,-40}}) do
    px,py=d.x+math.cos(angle)*view[2],d.y+math.sin(angle)*view[2]
    eyeHeight=view[3];rot=angle+math.pi;pitch=math.rad(view[4])
    previousPx,previousPy,previousEyeHeight=px,py,eyeHeight
    eyeStepOffset,previousEyeStepOffset=0,0;physicsAccumulator=0
    world:request(px,py);while world:hasPending() do world:step(256,world.upload) end
    for _,mode in ipairs({{'flat-reference',flat},{'sloped',sloped}}) do
      shader(mode[2]);local times={}
      for i=1,360 do
        local start=love.timer.getTime();love.draw();renderCanvas:newImageData():release()
        if i>60 then times[#times+1]=(love.timer.getTime()-start)*1000 end
      end
      table.sort(times)
      print(('%s %s 1920x1080: median %.3f ms p99 %.3f ms'):format(view[1],mode[1],times[150],times[297]))
    end
    local data=renderCanvas:newImageData();local png=data:encode('png')
    local file=assert(io.open(os.getenv('RAYCAST_OUTPUT')..'/'..view[1]..'.png','wb'));file:write(png:getString());file:close()
    data:release();png:release()
    shader(sloped);love.draw();local fast=renderCanvas:newImageData()
    shader(noSkip);love.draw();local slow=renderCanvas:newImageData()
    assert(fast:getString()==slow:getString(),'Flow surface differs with chunk skipping: '..view[1])
    fast:release();slow:release()
  end
  print('PASS: generated fall/landing/overview agree pixel-for-pixel with unaccelerated sloped rays')
end
function love.run()
  local ok,message=pcall(love.load);if not ok then print(message) end
  return function() return ok and 0 or 1 end
end
