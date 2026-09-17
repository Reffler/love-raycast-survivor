local originalLoad=love.load
function love.load()
  originalLoad();CONFIG.DEBUG_ENABLED=false
  love.window.setMode(1920,1080,{fullscreen=false,vsync=0});love.resize(love.graphics.getDimensions())
  dayPhase=1/6
  local ffi=require('ffi')
  local modern=raycastShader
  local source=love.filesystem.read('raycast.glsl')
  local baseline=love.graphics.newShader('#pragma language glsl3\n#define MAX_DDA_STEPS '..MAX_DDA_STEPS..'\n'..love.filesystem.read('before.glsl'))
  local stats=love.graphics.newShader('#pragma language glsl3\n#define AA_STATS\n#define MAX_DDA_STEPS '..MAX_DDA_STEPS..'\n'..source)
  local textures={}
  for name,file in pairs({dirtTex='dirt',grassSideTex='grass_block_side',grassTopTex='grass_block_top'}) do
    local tex=love.graphics.newImage('textures/'..file..'.png',{mipmaps=true});tex:setFilter('nearest','nearest');tex:setWrap('repeat','repeat');textures[name]=tex
  end
  local function bind(s)
    for _,tex in pairs(textures) do if s==baseline then tex:setFilter('linear','nearest');tex:setMipmapFilter('linear') else tex:setFilter('nearest','nearest');tex:setMipmapFilter('none') end end
    raycastShader=s;lastRot,lastPitch=nil,nil;updateProjection(love.graphics.getDimensions())
    for name,tex in pairs(textures) do if s:hasUniform(name) then s:send(name,tex) end end
    for name,value in pairs({heightTex=world.texture,chunkMaxTex=world.maxTexture,cacheSize=world.size,maxHeight=world.maxHeight,viewDist=CONFIG.VIEW_DIST}) do
      if s:hasUniform(name) then s:send(name,value) end
    end
  end
  local ordinaryCanvas=renderCanvas
  local statsCanvas=love.graphics.newCanvas(RENDER_W,RENDER_H,{format='rgba32f',dpiscale=1})
  local function frame() love.draw();renderCanvas:newImageData():release() end
  local csv=assert(io.open(os.getenv('SHADOW_OUTPUT')..'/profile.csv','w'))
  csv:write('view,mode,median_ms,p99_ms,max_ms,unique_mean,one_pct,two_pct,three_pct,four_pct,shadow_per_pixel,ao_per_pixel\n')
  print('Renderer: '..table.concat({love.graphics.getRendererInfo()},' | '))
  print('1920x1080, 556-block view, sun elevation 60 degrees, 200 timed frames per case; readback included, instrumentation excluded from timing')
  local function view(name,x,y,z,angle,tilt)
    px,py,eyeHeight=x,y,z;rot,pitch=math.rad(angle),math.rad(tilt)
    previousPx,previousPy,previousEyeHeight=x,y,z;eyeStepOffset,previousEyeStepOffset,physicsAccumulator=0,0,0
    world:request(x,y);while world:hasPending() do world:step(256,world.upload) end
    for _,distance in ipairs({-1,96}) do
      CONFIG.SHADOWS_ENABLED=true;CONFIG.SHADOW_DISTANCE=96
      local mode=distance<0 and 'before' or distance==0 and 'disabled' or 'enabled'
      renderCanvas=ordinaryCanvas;bind(distance<0 and baseline or modern)
      for i=1,20 do frame() end
      local times={}
      for i=1,200 do local t=love.timer.getTime();frame();times[i]=(love.timer.getTime()-t)*1000 end
      table.sort(times)
      local histogram={0,0,0,0};local unique,shadow,ao=0,0,0
      if distance>=0 then
        renderCanvas=statsCanvas;bind(stats);love.draw()
        local data=statsCanvas:newImageData();local pixels=ffi.cast('float*',data:getFFIPointer())
        for i=0,RENDER_W*RENDER_H-1 do
          local k=i*4;local n=math.floor(pixels[k]+0.5)
          assert(n>=1 and n<=4 and pixels[k+3]==4,'Invalid coverage instrumentation')
          histogram[n]=histogram[n]+1;unique=unique+n;shadow=shadow+pixels[k+1];ao=ao+pixels[k+2]
        end
        data:release()
      end
      local n=RENDER_W*RENDER_H
      local line=('%s,%s,%.4f,%.4f,%.4f,%.4f,%.3f,%.3f,%.3f,%.3f,%.4f,%.4f'):format(name,mode,times[100],times[198],times[200],unique/n,100*histogram[1]/n,100*histogram[2]/n,100*histogram[3]/n,100*histogram[4]/n,shadow/n,ao/n)
      print(line);csv:write(line..'\n');csv:flush()
      if distance==96 then
        renderCanvas=ordinaryCanvas;bind(modern);love.draw()
        local data=renderCanvas:newImageData();local file=assert(io.open(os.getenv('SHADOW_OUTPUT')..'/'..name..'.png','wb'));file:write(data:encode('png'):getString());file:close();data:release()
      end
    end
  end
  local h=world:height(3,3)
  view('ground',3.5,3.5,h+1.62,0,-20)
  view('horizon',3.5,3.5,h+30,45,0)
  view('downward',3.5,3.5,h+60,180,-65)
  local node
  for _,n in pairs(world.terrain.regions:get(0,0).caveNodes) do
    if n.active and n.x>=0 and n.x<1024 and n.y>=0 and n.y<1024 and (not node or n.radius>node.radius) then node=n end
  end
  assert(node,'Missing cave benchmark node')
  view('cave',node.x,node.y,node.z,0,-6)
  view('cave-ceiling',node.x,node.y,node.z,135,65)
  csv:close();renderCanvas=ordinaryCanvas
end
function love.run()
  local ok,err=pcall(love.load);world:stopWorker()
  if not ok then print(err) end
  return function() return ok and 0 or 1 end
end
