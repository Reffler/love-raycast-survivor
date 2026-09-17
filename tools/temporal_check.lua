local originalLoad=love.load
function love.load()
  originalLoad();world:stopWorker();CONFIG.DEBUG_ENABLED=false
  local ffi=require('ffi')
  -- Test resolve independently: unclipped history, rejected depth, sky and water.
  local w,h=8,8
  local function texture(depth,history,gradient)
    local data=love.image.newImageData(w,h,'rgba32f')
    data:mapPixel(function(x,y)
      local v=history and (gradient and (x+y*8)/64 or 0.4) or ((x+y)%2==0 and 0 or 1)
      if not history and x==4 and y==4 then v=0.2 end
      return v,v,v,depth=="edge" and (x<4 and 10 or 0) or depth
    end)
    local image=love.graphics.newImage(data);image:setFilter('nearest','nearest');data:release();return image
  end
  local target=love.graphics.newCanvas(w,h,{format='rgba32f',dpiscale=1})
  local function resolve(currentDepth,historyDepth,valid,delta,gradient)
    local current,history=texture(currentDepth,false),texture(historyDepth,true,gradient)
    local values={currentFrame=current,historyFrame=history,inverseSize={1/w,1/h},projection={1,1},
      forward={0,1,0},right={1,0,0},up={0,0,1},previousForward={0,1,0},previousRight={1,0,0},previousUp={0,0,1},cameraDelta=delta or {0,0,0},historyValid=valid,historyWeight=15/16}
    for name,value in pairs(values) do temporalShader:send(name,value) end
    love.graphics.setCanvas(target);love.graphics.setBlendMode('replace','premultiplied');love.graphics.setShader(temporalShader)
    love.graphics.rectangle('fill',0,0,w,h);love.graphics.setShader();love.graphics.setCanvas()
    local data=target:newImageData();local r,g,b,a=data:getPixel(4,4);data:release();current:release();history:release();return r,a
  end
  local function near(value,expected) assert(math.abs(value-expected)<1e-5,('Expected %.8f, got %.8f'):format(expected,value)) end
  near(resolve(10,10,true),0.3875)
  near(resolve(10,20,true),0.2)
  near(resolve(10,10,false),0.2)
  near(resolve(10,-10,true),0.2)
  near(resolve(-10,-10,true),0.3)
  near(resolve(0,0,true,{100,100,100}),0.3875)
  near(resolve(10,10,true,{1000,0,0}),0.2)
  near(resolve(10,10,true,{2.5,0,0},true),0.2/16+(37/64)*15/16)
  near(resolve(10,10,true,{0,0,2.5},true),0.2/16+(28/64)*15/16)
  near(resolve('edge',10,true),0.3875) -- Preserve subpixel silhouette coverage.
  near(resolve(0,10,true),0.2) -- Reject stale foreground outside an edge neighborhood.
  print('PASS: XY reprojection, silhouette history limited to edge neighborhoods')
  print('PASS: accumulation, disocclusion/depth/category rejection, water history limit, sky translation, screen bounds')
  target:release()

  love.window.setMode(320,180,{fullscreen=false,vsync=0});love.resize(love.graphics.getDimensions())
  assert(not temporal.valid and temporal.frame==0,'Resize retained history')
  local function draw() love.draw();return renderCanvas:newImageData() end
  draw():release();assert(temporal.valid and temporal.frame==1,'History bootstrap failed')
  love.keypressed('f5',nil,true);assert(CONFIG.AA_ENABLED,'Repeat toggled TAA')
  love.keypressed('f5',nil,false);assert(not CONFIG.AA_ENABLED and not temporal.valid,'Disable failed')
  local a=draw();local b=draw();assert(a:getString()==b:getString(),'Disabled renderer jitters');a:release();b:release()
  love.keypressed('f5',nil,false);draw():release();assert(temporal.frame==1,'Enable reused old history')
  love.keypressed('f4',nil,false);assert(not temporal.valid,'Shadow toggle retained history');love.keypressed('f4',nil,false)
  draw():release();rot=rot+math.pi;draw():release();assert(temporal.frame==1,'Camera cut retained history');rot=rot-math.pi
  px=px+16;previousPx=px;draw():release();assert(temporal.frame==1,'Teleport retained history')
  CONFIG.FOV_DEG=85;updateProjection(320,180);assert(not temporal.valid,'FOV change retained history');CONFIG.FOV_DEG=90;updateProjection(320,180)
  resetTemporal();local hidden=draw();local cleanHistory=temporal.history[temporal.index]:newImageData()
  CONFIG.DEBUG_ENABLED=true;hudElapsed=math.huge;resetTemporal();local shown=draw();local hudHistory=temporal.history[temporal.index]:newImageData()
  assert(hidden:getString()~=shown:getString(),'HUD did not draw')
  assert(cleanHistory:getString()==hudHistory:getString(),'HUD contaminated temporal history')
  hidden:release();shown:release();cleanHistory:release();hudHistory:release();CONFIG.DEBUG_ENABLED=false
  print('PASS: resize, F5/repeat, off-mode stability, F4, camera cut, teleport, FOV resets, HUD isolation')

  -- Controlled stepped terrain: all ordinary columns, no world streaming noise.
  for _,c in ipairs(world.chunks) do
    c.complex=false;c.maximum=48
    for i=0,255 do local y=c.requestY*16+math.floor(i/16);c.data[i]=math.min(48,8+math.floor(math.max(0,y)/4));c.surface[i]=0 end
    world.upload(c)
  end
  px,py,eyeHeight=15.98,-8,14;previousPx,previousPy,previousEyeHeight=px,py,eyeHeight
  rot,pitch=math.pi/2,-0.015;physicsAccumulator=0;eyeStepOffset,previousEyeStepOffset=0,0;dayPhase=1/6
  local function difference(a,b)
    local x,y=ffi.cast('uint8_t*',a:getFFIPointer()),ffi.cast('uint8_t*',b:getFFIPointer());local sum=0
    for i=0,320*180-1 do for c=0,2 do local d=x[i*4+c]-y[i*4+c];sum=sum+d*d end end
    return sum/(320*180*3)
  end
  local rawTarget=love.graphics.newCanvas(320,180,{format='rgba8',dpiscale=1})
  for _,moving in ipairs({false,true}) do
    resetTemporal();local lastRaw,lastResolved;local rawError,resolvedError=0,0
    for frame=1,80 do
      if moving then px=px+1/1024;previousPx=px end -- crosses a 16-block origin boundary
      local resolved=draw()
      love.graphics.setCanvas(rawTarget);love.graphics.setBlendMode('replace','premultiplied');love.graphics.setShader(presentShader)
      love.graphics.draw(temporal.current);love.graphics.setShader();love.graphics.setCanvas()
      local raw=rawTarget:newImageData()
      if frame>32 then rawError=rawError+difference(raw,lastRaw);resolvedError=resolvedError+difference(resolved,lastResolved) end
      if lastRaw then lastRaw:release();lastResolved:release() end
      lastRaw,lastResolved=raw,resolved
      if frame==80 then local f=assert(io.open(os.getenv('TAA_OUTPUT')..'/'..(moving and 'moving' or 'static')..'.png','wb'));f:write(resolved:encode('png'):getString());f:close() end
    end
    lastRaw:release();lastResolved:release()
    assert(temporal.frame==80,'Ordinary motion or origin rebase reset history')
    print('MSE raw/resolved',rawError/48,resolvedError/48)
    assert(resolvedError<rawError*0.05,'Temporal resolve did not reduce staircase instability')
    print(('PASS: %s staircase RMS frame change raw %.4f, TAA %.4f (8-bit RGB)'):format(moving and 'moving/rebased' or 'static',math.sqrt(rawError/48),math.sqrt(resolvedError/48)))
  end
  rawTarget:release()
end
function love.run()
  local ok,err=pcall(love.load);if world then world:stopWorker() end
  if not ok then print(err) end
  return function() return ok and 0 or 1 end
end
