local originalLoad=love.load
function love.load()
  originalLoad();CONFIG.DEBUG_ENABLED=false
  love.window.setMode(640,360,{fullscreen=false,vsync=0});love.resize(love.graphics.getDimensions())
  local modern=raycastShader
  local legacy=love.graphics.newShader('#define MAX_DDA_STEPS '..MAX_DDA_STEPS..'\n'..assert(love.filesystem.read('legacy.glsl')))
  local noSkip=love.graphics.newShader('#define MAX_DDA_STEPS '..MAX_DDA_STEPS..'\n'..assert(love.filesystem.read('raycast.glsl')):gsub('if %(min%(camPos.z','if (false && min(camPos.z'))
  local function render(shader)
    raycastShader=shader;lastRot,lastPitch=nil,nil;updateProjection(love.graphics.getDimensions())
    shader:send('heightTex',world.texture)
    if shader:hasUniform('chunkMaxTex') then shader:send('chunkMaxTex',world.maxTexture) end
    shader:send('cacheSize',world.size);shader:send('maxHeight',world.maxHeight);shader:send('viewDist',CONFIG.VIEW_DIST)
    previousPx,previousPy,previousEyeHeight=px,py,eyeHeight;eyeStepOffset,previousEyeStepOffset=0,0;physicsAccumulator=0
    love.draw();local d=renderCanvas:newImageData();local bytes=d:getString();d:release();return bytes
  end
  local function flags(complex)
    for _,c in ipairs(world.chunks) do if c.x~=math.huge then
      c.complex=complex
      if complex then
        require('ffi').fill(c.spans,4096,255)
        for i=0,255 do c.spans[i*8]=0;c.spans[i*8+1]=c.data[i] end
      end
      world.upload(c)
    end end
  end
  local comparisons=0
  for _,point in ipairs({{3.5,3.5},{-16.5,-32.5},{1023.5,1024.5}}) do
    px,py=unpack(point);world:request(px,py);while world:hasPending() do world:step(256,world.upload) end
    for _,v in ipairs({{0,-20,40},{45,0,2},{90,-80,20},{180,35,2}}) do
      rot,pitch=math.rad(v[1]),math.rad(v[2]);eyeHeight=world:height(math.floor(px),math.floor(py))+v[3]
      flags(false);local expected=render(legacy);assert(render(modern)==expected,'Ordinary path changed framebuffer')
      flags(true);assert(render(modern)==expected,'Single spans changed framebuffer');assert(render(noSkip)==expected,'Span chunk skipping mismatch')
      comparisons=comparisons+1
    end
  end
  px,py=8,8;world:request(px,py);while world:hasPending() do world:step(256,world.upload) end
  for _,c in ipairs(world.chunks) do
    for i=0,255 do c.data[i]=40;c.surface[i]=2048+(c.x<0 and 72 or 48+(i%8)/8)*8 end
    c.maximum=72
  end
  for _,v in ipairs({{60,180,0},{44,0,-90},{90,180,-30},{47,0,0}}) do
    eyeHeight=v[1];rot,pitch=math.rad(v[2]),math.rad(v[3])
    flags(false);local expected=render(legacy);flags(true)
    assert(render(modern)==expected and render(noSkip)==expected,'Water/slope/fall changed with single spans')
    comparisons=comparisons+1
  end
  local expected=render(modern);world.forceSpans=true;world:initGraphics(px,py)
  assert(render(modern)==expected,'Graphics reload changed spans')
  print('PASS: '..comparisons..' exact legacy/single-span framebuffers; water, waterfalls, negative coordinates, macro boundary, skip and reload')
  world.forceSpans=false
  for _,c in ipairs(world.chunks) do
    c.complex=true;c.maximum=70
    for i=0,255 do
      c.data[i]=70;c.surface[i]=0
      for j=0,3 do c.spans[i*8+j*2]=j*20;c.spans[i*8+j*2+1]=j*20+10 end
    end
    world.upload(c)
  end
  local function pixel(z,tilt)
    px,py,eyeHeight=8,8,z;rot,pitch=0,tilt
    local bytes=render(modern);assert(bytes==render(noSkip),'Four-span skipping mismatch')
    local k=(180*640+320)*4
    return bytes:byte(k+1)/255,bytes:byte(k+2)/255,bytes:byte(k+3)/255
  end
  for _,z in ipairs({15,35,55}) do
    local r,g,b=pixel(z,-math.pi/2);assert(math.abs(r-0.43)<0.01 and math.abs(b-0.48)<0.01,'Cave floor ray missed')
    r,g,b=pixel(z,math.pi/2);assert(math.abs(r-0.43*0.64)<0.01 and math.abs(b-0.48*0.64)<0.01,'Cave ceiling ray missed')
  end
  local r,g,b=pixel(75,-math.pi/2);assert(math.abs(g-0.62)<0.01,'Topmost grass surface lost material')
  -- Full solid neighbor of a cave still exposes an interior rock wall.
  for _,c in ipairs(world.chunks) do
    for i=0,255 do if c.x*16+i%16>=12 then
      for j=0,7 do c.spans[i*8+j]=-1 end
      c.spans[i*8],c.spans[i*8+1]=0,70
    end end
    world.upload(c)
  end
  r,g,b=pixel(15,0);assert(math.abs(r-0.43*0.72)<0.01,'Interior vertical wall missing or wrong material')
  print('PASS: four-span GPU floors, ceilings, upper surface material and interior wall')
  local before=render(modern);world:initGraphics(px,py);assert(render(modern)==before,'Complex graphics reload changed pixels')
  local probe=love.graphics.newShader([[
    extern Image a;extern Image b;extern vec2 uv;
    vec4 effect(vec4 c,Image t,vec2 tc,vec2 sc) {return sc.y<1.0 ? Texel(a,uv) : Texel(b,uv);}
  ]])
  local target=love.graphics.newCanvas(1,2,{format='rgba32f',dpiscale=1})
  probe:send('a',world.spanTex0);probe:send('b',world.spanTex1)
  for _,p in ipairs({{-3,-17},{12,8},{16,-1}}) do
    local x,y=unpack(p);local c=world.chunks[world:slot(math.floor(x/16),math.floor(y/16))];local k=((y%16)*16+x%16)*8
    local values={0,7,11,93,107,254,-1,-1}
    for j=0,7 do c.spans[k+j]=values[j+1] end
    world.upload(c)
    probe:send('uv',{(x%world.size+0.5)/world.size,(y%world.size+0.5)/world.size})
    love.graphics.setCanvas(target);love.graphics.setShader(probe);love.graphics.setBlendMode('replace','premultiplied');love.graphics.rectangle('fill',0,0,1,2)
    love.graphics.setShader();love.graphics.setCanvas();local d=target:newImageData()
    for row=0,1 do local channels={d:getPixel(0,row)};for j=1,4 do assert(channels[j]==values[row*4+j],('Half-float span / negative cache wrap mismatch x%d y%d row%d channel%d actual%g expected%g'):format(x,y,row,j,channels[j],values[row*4+j])) end end
    d:release()
  end
  target:release();probe:release()
  print('PASS: true complex reload and exact RGBA16F boundaries / unused -1 at negative and chunk seams')


end
function love.run()
  local ok,err=pcall(love.load);if not ok then print(err) end
  return function() return ok and 0 or 1 end
end
