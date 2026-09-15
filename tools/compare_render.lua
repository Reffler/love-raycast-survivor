local originalLoad=love.load
function love.load()
  originalLoad();CONFIG.DEBUG_ENABLED=false
  love.window.setMode(1920,1080,{fullscreen=false,vsync=0});love.resize(love.graphics.getDimensions())
  print('Renderer: '..table.concat({love.graphics.getRendererInfo()},' | '))
  local shaders={love.graphics.newShader('#define MAX_DDA_STEPS '..MAX_DDA_STEPS..'\n'..love.filesystem.read('reference.glsl')),raycastShader}
  local function render(i)
    raycastShader=shaders[i];lastRot,lastPitch=nil,nil
    updateProjection(love.graphics.getDimensions())
    raycastShader:send('heightTex',world.texture);raycastShader:send('chunkMaxTex',world.maxTexture)
    raycastShader:send('cacheSize',world.size);raycastShader:send('maxHeight',world.maxHeight);raycastShader:send('viewDist',CONFIG.VIEW_DIST)
    love.draw();return renderCanvas:newImageData()
  end
  local function view(name,x,y,z,angle,tilt,checkOnly)
    px,py,eyeHeight=x,y,z;rot,pitch=math.rad(angle),math.rad(tilt)
    world:request(x,y);while world:hasPending() do world:step(256,world.upload) end
    previousPx,previousPy,previousEyeHeight=x,y,z;eyeStepOffset,previousEyeStepOffset,physicsAccumulator=0,0,0
    local a,b=render(1),render(2)
    assert(a:getString()==b:getString(),'Pixels differ: '..name);a:release();b:release()
    if checkOnly then return end
    local times={{},{}}
    for frame=1,100 do
      for order=1,2 do
        local i=(frame+order)%2+1
        local start=love.timer.getTime();render(i):release()
        if frame>20 then times[i][#times[i]+1]=(love.timer.getTime()-start)*1000 end
      end
    end
    for i=1,2 do table.sort(times[i]) end
    print(('VIEW,%s,reference_ms,%.4f,current_ms,%.4f,speedup_pct,%.2f,exact_pixels,PASS'):format(name,times[1][40],times[2][40],(times[1][40]/times[2][40]-1)*100))
  end
  local h=world:height(3,3)
  view('ground',3.5,3.5,h+1.62,0,-20)
  view('horizon',3.5,3.5,h+30,45,0)
  view('downward',3.5,3.5,h+60,180,-65)
  local region=world.terrain.regions:get(0,0);local node
  for _,n in pairs(region.caveNodes) do
    if n.active and n.x>=0 and n.x<1024 and n.y>=0 and n.y<1024 and (not node or n.radius>node.radius) then node=n end
  end
  assert(node,'Missing cave fixture')
  view('cave',node.x,node.y,node.z,0,-6)
  view('cave-ceiling',node.x,node.y,node.z,135,65)
  for _,p in ipairs({{-32.5,-64.5},{1023.5,1024.5},{1000000.5,-1000000.5}}) do
    local z=world:height(math.floor(p[1]),math.floor(p[2]))+20
    for angle=0,315,45 do view('seams-'..angle,p[1],p[2],z,angle,-25,true) end
  end
  print('PASS: 24 exact reference views across negative, region-boundary and far coordinates')
  -- Controlled ocean and fractional flowing water exercise the other traversal paths.
  for _,c in ipairs(world.chunks) do
    c.complex=false;c.maximum=48
    for i=0,255 do c.data[i]=40;c.surface[i]=2048+48*8 end
    world.upload(c)
  end
  view('ocean',px,py,50,0,-5)
  for _,c in ipairs(world.chunks) do
    c.maximum=49
    for i=0,255 do c.surface[i]=2048+(48+(i%8)/8)*8 end
    world.upload(c)
  end
  view('flowing-water',px,py,50,45,-20)
end
function love.run()
  local ok,err=pcall(love.load);if not ok then print(err) end
  return function() return ok and 0 or 1 end
end
