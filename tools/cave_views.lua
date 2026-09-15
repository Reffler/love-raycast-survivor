local originalLoad=love.load
function love.load()
  originalLoad();CONFIG.DEBUG_ENABLED=false
  love.window.setMode(960,540,{fullscreen=false,vsync=0});love.resize(love.graphics.getDimensions())
  local modern=raycastShader
  local source=assert(love.filesystem.read('raycast.glsl'))
  local noSkip=love.graphics.newShader('#define MAX_DDA_STEPS '..MAX_DDA_STEPS..'\n'..source:gsub('if %(min%(camPos.z','if (false && min(camPos.z'))
  local function shader(s)
    raycastShader=s;lastRot,lastPitch=nil,nil;updateProjection(love.graphics.getDimensions())
    s:send('heightTex',world.texture)
    if s:hasUniform('chunkMaxTex') then s:send('chunkMaxTex',world.maxTexture) end
    s:send('cacheSize',world.size);s:send('maxHeight',world.maxHeight);s:send('viewDist',CONFIG.VIEW_DIST)
  end
  local function camera(x,y,z,tx,ty,tz)
    px,py,eyeHeight=x,y,z;rot=math.atan2(ty-y,tx-x);pitch=math.atan2(tz-z,math.sqrt((tx-x)^2+(ty-y)^2))
    world:request(px,py);while world:hasPending() do world:step(256,world.upload) end
    previousPx,previousPy,previousEyeHeight=px,py,eyeHeight;eyeStepOffset,previousEyeStepOffset=0,0;physicsAccumulator=0
  end
  local function capture(name)
    shader(modern);love.draw();local a=renderCanvas:newImageData()
    shader(noSkip);love.draw();local b=renderCanvas:newImageData()
    assert(a:getString()==b:getString(),'Complex chunk skipping mismatch '..name)
    local png=a:encode('png');local f=assert(io.open(os.getenv('SPAN_OUTPUT')..'/'..name..'.png','wb'));f:write(png:getString());f:close()
    a:release();b:release();png:release();print('VIEW '..name)
    shader(modern)
  end
  for _,seed in ipairs({1337,716701,452312}) do
    world:releaseGraphics();world=World.new(seed,CONFIG.VIEW_DIST);world:initGraphics(0,0)
    local chosen,node,arch
    for ry=-1,1 do for rx=-1,1 do
      local r=world.terrain.regions:get(rx,ry)
      if not arch and #r.caveFeatures>0 then arch=r.caveFeatures[1] end
      for _,e in ipairs(r.caveEntrances) do if e.type=='cliff' and (not chosen or e.radius>chosen.radius) then
        chosen={x=e.x,y=e.y,z=e.z,dx=e.dx,dy=e.dy,radius=e.radius}
      end end
      for _,n in pairs(r.caveNodes) do if n.active and n.radius>10 and (not node or n.radius>node.radius) then node={x=n.x,y=n.y,z=n.z,radius=n.radius} end end
    end end
    assert(chosen and node,'Seed lacks entrance/chamber')
    local e=chosen
    print(('ENTRANCE %d %.1f %.1f %.1f radius %.1f'):format(seed,e.x,e.y,e.z,e.radius))
    camera(e.x+e.dx*55,e.y+e.dy*55,e.z+15,e.x,e.y,e.z);capture('entrance-'..seed)
    camera(e.x+e.dx*10,e.y+e.dy*10,e.z,e.x-e.dx*40,e.y-e.dy*40,e.z-10);capture('mouth-'..seed)
    camera(node.x,node.y,node.z,node.x+30,node.y+5,node.z-3);capture('chamber-'..seed)
    if arch then
      print(('ARCH %d %.1f %.1f %.1f'):format(seed,arch.x,arch.y,arch.z))
      camera(arch.x+arch.dx*65,arch.y+arch.dy*65,arch.z+2,arch.x,arch.y,arch.z);capture('arch-'..seed)
    end
  end
end
function love.run()
  local ok,err=pcall(love.load);if not ok then print(err) end
  return function() return ok and 0 or 1 end
end
