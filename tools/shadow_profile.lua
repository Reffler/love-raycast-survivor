local originalLoad=love.load
function love.load()
  originalLoad();CONFIG.DEBUG_ENABLED=false
  love.window.setMode(1920,1080,{fullscreen=false,vsync=0});love.resize(love.graphics.getDimensions())
  dayPhase=1/6
  local ffi=require('ffi')
  local modern=raycastShader
  local source=love.filesystem.read('raycast.glsl')
  local baseline=love.graphics.newShader('#pragma language glsl3\n#define MAX_DDA_STEPS '..MAX_DDA_STEPS..'\n'..love.filesystem.read('before.glsl'))
  local stats=love.graphics.newShader('#pragma language glsl3\n#define SHADOW_STATS\n#define MAX_DDA_STEPS '..MAX_DDA_STEPS..'\n'..source)
  local textures={}
  for name,file in pairs({dirtTex='dirt',grassSideTex='grass_block_side',grassTopTex='grass_block_top'}) do
    local tex=love.graphics.newImage('textures/'..file..'.png');tex:setFilter('nearest','nearest');tex:setWrap('repeat','repeat');textures[name]=tex
  end
  local function bind(s)
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
  csv:write('view,mode,distance,median_ms,p99_ms,max_ms,cells_per_front_pixel,chunks_skipped_per_front_pixel,backface_pct_solid,above_max_pct_rays,occluder_pct_rays,complex_cells_per_ray,cache_exit_pct_rays,unloaded_pct_rays\n')
  print('Renderer: '..table.concat({love.graphics.getRendererInfo()},' | '))
  print('1920x1080, 556-block view, sun elevation 60 degrees, 200 timed frames per case; readback included, instrumentation excluded from timing')
  local function view(name,x,y,z,angle,tilt)
    px,py,eyeHeight=x,y,z;rot,pitch=math.rad(angle),math.rad(tilt)
    previousPx,previousPy,previousEyeHeight=x,y,z;eyeStepOffset,previousEyeStepOffset,physicsAccumulator=0,0,0
    world:request(x,y);while world:hasPending() do world:step(256,world.upload) end
    for _,distance in ipairs({-1,0,32,64,96,128}) do
      CONFIG.SHADOWS_ENABLED=distance>0;CONFIG.SHADOW_DISTANCE=math.max(0,distance)
      local mode=distance<0 and 'before' or distance==0 and 'disabled' or 'enabled'
      renderCanvas=ordinaryCanvas;bind(distance<0 and baseline or modern)
      for i=1,20 do frame() end
      local times={}
      for i=1,200 do local t=love.timer.getTime();frame();times[i]=(love.timer.getTime()-t)*1000 end
      table.sort(times)
      local cells,skips,solid,front,back,cast,above,occluder,complex,cache,unloaded=0,0,0,0,0,0,0,0,0,0,0
      if distance>=0 then
        renderCanvas=statsCanvas;bind(stats);love.draw()
        local data=statsCanvas:newImageData();local pixels=ffi.cast('float*',data:getFFIPointer())
        for i=0,RENDER_W*RENDER_H-1 do
          local k=i*4;local code=pixels[k+2]
          if code>0 then
            solid=solid+1
            if code==1 then back=back+1 else front=front+1 end
            if code>=3 then
              cast=cast+1;cells=cells+pixels[k];skips=skips+pixels[k+1];complex=complex+pixels[k+3]
              if code==4 then above=above+1 elseif code==5 then occluder=occluder+1 elseif code==6 then cache=cache+1 elseif code==7 then unloaded=unloaded+1 end
            end
          end
        end
        data:release()
        assert(cache==0 and unloaded==0,'Profile attempted nonresident shadow reads')
      end
      local line=('%s,%s,%d,%.4f,%.4f,%.4f,%.4f,%.4f,%.3f,%.3f,%.3f,%.4f,%.3f,%.3f'):format(name,mode,math.max(0,distance),times[100],times[198],times[200],cells/math.max(1,front),skips/math.max(1,front),100*back/math.max(1,solid),100*above/math.max(1,cast),100*occluder/math.max(1,cast),complex/math.max(1,cast),100*cache/math.max(1,cast),100*unloaded/math.max(1,cast))
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
