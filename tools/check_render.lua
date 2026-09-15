local originalLoad=love.load
function love.load()
  originalLoad()
  love.window.setMode(960,540,{fullscreen=false,vsync=0})
  love.resize(love.graphics.getDimensions())
  love.draw()
  local hidden=renderCanvas:newImageData();local bytes=hidden:getString();hidden:release()
  love.keypressed('f3');love.draw()
  local shown=renderCanvas:newImageData();assert(shown:getString()~=bytes);shown:release()
  love.keypressed('f3');love.draw()
  hidden=renderCanvas:newImageData();assert(hidden:getString()==bytes);hidden:release()
  for _,size in ipairs({{960,540},{600,800}}) do
    love.window.setMode(size[1],size[2],{fullscreen=false,vsync=0})
    love.resize(love.graphics.getDimensions());love.draw()
    assert(RENDER_W==love.graphics.getPixelWidth() and RENDER_H==love.graphics.getPixelHeight())
    local frame=renderCanvas:newImageData();local expected=frame:getString();frame:release()
    love.graphics.captureScreenshot(function(data)
      assert(data:getString()==expected,'Native presentation changed pixels');data:release()
    end)
    love.graphics.present()
  end
  love.window.setMode(960,540,{fullscreen=false,vsync=0});love.resize(love.graphics.getDimensions())
  -- Real uploaded height data must agree with CPU, including wrapped negative slots.
  local probe=love.graphics.newShader([[
    extern Image heights;extern vec2 uv;
    vec4 effect(vec4 c,Image t,vec2 tc,vec2 sc){return vec4(floor(Texel(heights,uv).r/8.0),0.0,0.0,1.0);}
  ]])
  probe:send('heights',world.texture)
  local target=love.graphics.newCanvas(1,1,{format='rgba32f',dpiscale=1})
  for _,position in ipairs({{3.5,3.5},{-64.5,32.5},{1000000.5,-1000000.5}}) do
    px,py=unpack(position);world:request(px,py)
    while world:hasPending() do world:step(256,world.upload) end
    for y=math.floor(py)-CONFIG.VIEW_DIST,math.floor(py)+CONFIG.VIEW_DIST,16 do for x=math.floor(px)-CONFIG.VIEW_DIST,math.floor(px)+CONFIG.VIEW_DIST,16 do
      probe:send('uv',{(x%world.size+0.5)/world.size,(y%world.size+0.5)/world.size})
      love.graphics.setCanvas(target);love.graphics.setBlendMode('replace');love.graphics.setShader(probe);love.graphics.rectangle('fill',0,0,1,1)
      love.graphics.setShader();love.graphics.setCanvas()
      local data=target:newImageData();assert(data:getPixel(0,0)==world:height(x,y),('GPU/CPU terrain mismatch %d,%d: %s / %s'):format(x,y,data:getPixel(0,0),world:height(x,y)));data:release()
    end end
    eyeHeight=world:height(math.floor(px),math.floor(py))+CONFIG.CAM_HEIGHT
    previousPx,previousPy,previousEyeHeight=px,py,eyeHeight
    for _,view in ipairs({{0,-25},{90,0},{180,-60},{270,75}}) do
      rot,pitch=math.rad(view[1]),math.rad(view[2]);love.draw()
    end
  end
  target:release();probe:release()
  -- Analytic grid crossings must agree pixel-for-pixel with ordinary DDA.
  local accelerated=raycastShader
  local referenceSource=assert(love.filesystem.read('raycast.glsl')):gsub('if %(min%(camPos.z','if (false && min(camPos.z')
  local reference=love.graphics.newShader('#define MAX_DDA_STEPS '..MAX_DDA_STEPS..'\n'..referenceSource)
  local function renderWith(shader)
    raycastShader=shader;lastRot,lastPitch=nil,nil
    updateProjection(love.graphics.getDimensions())
    shader:send('heightTex',world.texture)
    if shader:hasUniform('chunkMaxTex') then shader:send('chunkMaxTex',world.maxTexture) end
    shader:send('cacheSize',world.size);shader:send('maxHeight',world.maxHeight);shader:send('viewDist',CONFIG.VIEW_DIST)
    love.draw()
    return renderCanvas:newImageData()
  end
  local ffi=require('ffi')
  for _,altitude in ipairs({CONFIG.CAM_HEIGHT,12,35}) do
    eyeHeight=world:height(math.floor(px),math.floor(py))+altitude;previousEyeHeight=eyeHeight
    for _,view in ipairs({{0,0},{45,-5},{90,-25},{180,10},{270,-75}}) do
      rot,pitch=math.rad(view[1]),math.rad(view[2])
      local a,b=renderWith(accelerated),renderWith(reference)
      local aa,bb=ffi.cast('uint32_t*',a:getFFIPointer()),ffi.cast('uint32_t*',b:getFFIPointer())
      local different=0
      for i=0,RENDER_W*RENDER_H-1 do if aa[i]~=bb[i] then different=different+1 end end
      assert(different==0,('Chunk skip changed %d pixels'):format(different))
      a:release();b:release()
    end
  end
  raycastShader=accelerated;lastRot,lastPitch=nil,nil;reference:release()
  print('PASS: chunk skipping agrees with unaccelerated DDA exactly across 15 horizon/height/pitch views')

  -- Sprint across many chunk boundaries; every visible chunk must already be resident.
  local maxUpdate=0
  for i=1,3600 do
    local x,y=px+i*5/60,py+i*3/60
    local t=love.timer.getTime();world:update(x,y);maxUpdate=math.max(maxUpdate,love.timer.getTime()-t)
    for dy=-CONFIG.VIEW_DIST,CONFIG.VIEW_DIST,16 do for dx=-CONFIG.VIEW_DIST,CONFIG.VIEW_DIST,16 do
      local cx,cy=math.floor((x+dx)/16),math.floor((y+dy)/16)
      local chunk=world.chunks[world:slot(cx,cy)]
      assert(chunk and chunk.x==cx and chunk.y==cy,'Streaming fell behind movement')
    end end
  end
  px,py=3.5,3.5;world:request(px,py)
  while world:hasPending() do world:step(256,world.upload) end
  eyeHeight=world:height(3,3)+CONFIG.CAM_HEIGHT
  previousPx,previousPy,previousEyeHeight=px,py,eyeHeight;rot,pitch=0,math.rad(-20)
  love.draw()
  local data=renderCanvas:newImageData();local png=data:encode('png')
  local file=assert(io.open(os.getenv('RAYCAST_OUTPUT')..'/terrain.png','wb'));file:write(png:getString());file:close()
  data:release();png:release()
  -- Every supported integer is exact in both formats, including uploaded maxima.
  local formatProbe=love.graphics.newShader([[
    extern Image heights;extern Image maxima;extern float size;
    vec4 effect(vec4 c,Image t,vec2 tc,vec2 sc) {
      return vec4(Texel(heights,sc/size).rg,Texel(maxima,vec2(0.5)/(size/16.0)).r,1.0);
    }
  ]])
  local formatTarget=love.graphics.newCanvas(16,16,{format='rgba32f',dpiscale=1})
  for _,format in ipairs({'r32f','r16f'}) do
    local w=World.new(1337,16,{caves=false});local prepared=w:generateChunk(0,0);w:initGraphics(0,0,format)
    formatProbe:send('heights',w.texture);formatProbe:send('maxima',w.maxTexture);formatProbe:send('size',w.size)
    love.graphics.setCanvas(formatTarget);love.graphics.setShader(formatProbe);love.graphics.setBlendMode('replace')
    love.graphics.rectangle('fill',0,0,16,16);love.graphics.setShader();love.graphics.setCanvas()
    local initial=formatTarget:newImageData()
    for i=0,255 do assert(math.floor(initial:getPixel(i%16,math.floor(i/16))/8)==prepared.data[i],'Prepared chunk missing from initial GPU upload') end
    initial:release()
    local chunk=w:generateChunk(0,0)
    for base=0,1792,256 do
      for i=0,255 do chunk.data[i]=math.min(i,254);chunk.surface[i]=((i+base/256)%5)*2048+base+i end
      chunk.maximum=math.min(base+255,2048);w.upload(chunk)
      love.graphics.setCanvas(formatTarget);love.graphics.setShader(formatProbe);love.graphics.setBlendMode('replace')
      love.graphics.rectangle('fill',0,0,16,16);love.graphics.setShader();love.graphics.setCanvas()
      local result=formatTarget:newImageData()
      for i=0,255 do
        local height,code,maximum=result:getPixel(i%16,math.floor(i/16))
        assert(height==chunk.data[i]*8+math.floor(chunk.surface[i]/2048) and code==chunk.surface[i]%2048 and maximum==chunk.maximum,'Height format lost integer precision: '..format)
      end
      result:release()
    end
    w.texture:release();w.imageData:release();w.tile:release();w.maxTexture:release();w.maxData:release();w.maxTile:release()
  end
  formatProbe:release();formatTarget:release()
  print('PASS: rg16f/rg32f exact terrain/material packing, maxima and all 2048 eighth-block water codes')
  -- Controlled water volumes: top, submerged bed, and vertical drop must be
  -- separate intersections, using the same packed texture as generated terrain.
  world=World.new(1337,16,{caves=false});world:initGraphics(8,8)
  for _,chunk in ipairs(world.chunks) do
    if chunk.x~=math.huge then
      for y=0,15 do for x=0,15 do
        local i=y*16+x;chunk.data[i]=40
        chunk.surface[i]=2048+(chunk.x*16+x<0 and 72 or 48)*8
      end end
      chunk.maximum=72;world.upload(chunk)
    end
  end
  px,py=8,8;previousPx,previousPy=px,py
  eyeStepOffset,previousEyeStepOffset=0,0;physicsAccumulator=0
  local function center(z,angle,tilt)
    eyeHeight=z;previousEyeHeight=z;rot=angle;pitch=tilt
    local data=renderWith(accelerated)
    local red,green,blue=data:getPixel(math.floor(RENDER_W/2),math.floor(RENDER_H/2));data:release()
    return red,green,blue
  end
  local red,green,blue=center(60,math.pi,0)
  assert(math.abs(red-0.16)<0.01 and math.abs(green-0.51)<0.01 and math.abs(blue-0.57)<0.01,'Drop lacks vertical water face')
  px=-8;previousPx=px
  red,green,blue=center(60,0,0)
  assert(math.abs(red-0.16)<0.01 and math.abs(green-0.51)<0.01,'Water volume exit face missing')
  px=8;previousPx=px
  red,green,blue=center(44,0,-math.pi/2)
  assert(math.abs(red-0.76)<0.01 and math.abs(green-0.69)<0.01,'Submerged bed replaced by water height')
  red,green,blue=center(60,0,-math.pi/2)
  assert(blue>red and green>red,'Water top failed nearest intersection')
  print('PASS: flat water top, submerged terrain bed, explicit vertical waterfall intersection')
  -- Exercise both GPU triangles and shared corner rules with analytic answers.
  local source=assert(love.filesystem.read('raycast.glsl'))
  local prefix=source:sub(1,assert(source:find('vec4 effect(',1,true))-1)
  local slopeProbe=love.graphics.newShader(prefix..[[
    vec4 effect(vec4 c,Image t,vec2 tc,vec2 sc) {
      vec4 h=vec4(79.0,78.875,78.875,78.75);
      return vec4(triangleHit(vec3(0,0,-1),vec2(0),h,0.0,10.0),
        cornerHeight(78.875,78.75,78.625,78.5),
        cornerHeight(78.875,79.0,78.625,0.0),1.0);
    }
  ]])
  local slopeTarget=love.graphics.newCanvas(1,1,{format='rgba32f',dpiscale=1})
  slopeProbe:send('viewDist',256)
  for _,p in ipairs({0.25,0.75}) do
    slopeProbe:send('camPos',{p,p,80})
    love.graphics.setCanvas(slopeTarget);love.graphics.setShader(slopeProbe)
    love.graphics.setBlendMode('replace');love.graphics.rectangle('fill',0,0,1,1)
    love.graphics.setShader();love.graphics.setCanvas()
    local data=slopeTarget:newImageData();local hit,average,full=data:getPixel(0,0)
    assert(math.abs(hit-(1+p/4))<1e-6 and average==78.6875 and full==79,'Water triangle/corner mismatch')
    data:release()
  end
  slopeProbe:release();slopeTarget:release()
  print('PASS: both sloped GPU triangles, shared fractional corners, full-height edge and dry exclusion')
  print(('PASS: native resize/presentation, HUD, GPU/CPU heights, negative/far chunks, sprint streaming; max streaming update %.3f ms'):format(maxUpdate*1000))
end
function love.run()
  local ok,message=pcall(love.load)
  if not ok then print(message) end
  return function() return ok and 0 or 1 end
end
