local originalLoad=love.load
function love.load()
  originalLoad();world:stopWorker()
  assert(CONFIG.AA_ENABLED,'AA should start enabled')
  love.keypressed('f5',nil,true);assert(CONFIG.AA_ENABLED,'Repeat toggled AA')
  love.keypressed('f5',nil,false);assert(not CONFIG.AA_ENABLED,'F5 did not disable AA')
  love.keypressed('f5',nil,false);assert(CONFIG.AA_ENABLED,'F5 did not enable AA')
  local ffi=require('ffi')
  local source=love.filesystem.read('raycast.glsl')
  local prefix='#pragma language glsl3\n#define MAX_DDA_STEPS '..MAX_DDA_STEPS..'\n'
  local grouped=love.graphics.newShader(prefix..source)
  -- Independent four-sample resolve: bypass grouping but use identical visibility/shading.
  local independent=love.graphics.newShader(prefix..source:gsub('if %(sameKey%(keys%[i%],keys%[j%]%)%) {','if (false) {'))
  local stats=love.graphics.newShader(prefix..'#define AA_STATS\n'..source)
  world:releaseGraphics();world=World.new(1337,128,{caves=false});world:initGraphics(0,0)
  local boxes={}
  local function reset(height)
    boxes={}
    for _,c in ipairs(world.chunks) do
      c.maximum=height;c.complex=false
      ffi.fill(c.spans,4096,255)
      for i=0,255 do c.data[i]=height;c.surface[i]=0;c.spans[i*8]=0;c.spans[i*8+1]=height end
    end
  end
  local function column(x,y,intervals)
    local c=world.chunks[world:slot(math.floor(x/16),math.floor(y/16))]
    local i=(y%16)*16+x%16
    for j=0,7 do c.spans[i*8+j]=-1 end
    for j,b in ipairs(intervals) do
      c.spans[i*8+(j-1)*2],c.spans[i*8+(j-1)*2+1]=b[1],b[2]
      boxes[#boxes+1]={x,y,b[1],x+1,y+1,b[2]}
    end
    c.data[i]=intervals[#intervals][2]
    c.maximum=math.max(c.maximum,tonumber(c.data[i]))
    c.complex=c.complex or #intervals>1 or intervals[1][1]>0
  end
  local function upload() for _,c in ipairs(world.chunks) do world.upload(c) end end
  local textures={}
  for name,file in pairs({dirtTex='dirt',grassSideTex='grass_block_side',grassTopTex='grass_block_top'}) do
    local t=love.graphics.newImage('textures/'..file..'.png');t:setFilter('nearest','nearest');t:setWrap('repeat','repeat');textures[name]=t
  end
  local target=love.graphics.newCanvas(96,64,{format='rgba32f',dpiscale=1})
  local function capture(shader,x,z,pitch,enabled)
    local cp,sp=math.cos(pitch),math.sin(pitch)
    local uniforms={aaEnabled=enabled~=false,heightTex=world.texture,chunkMaxTex=world.maxTexture,spanTex0=world.spanTex0,spanTex1=world.spanTex1,
      cacheSize=world.size,cacheOffset={0,0},maxHeight=64,viewDist=120,camPos={x,-8,z},camForward={0,cp,sp},camRight={1,0,0},camUp={0,-sp,cp},
      tanHalfHFOV=0.7,tanHalfVFOV=0.7*64/96,skyTint={0.5,0.7,0.9},zenithTint={0.2,0.4,0.8},lightTint={1,1,1},directTint={1,1,1},
      sunDirection={0.48,0.36,0.8},sunStrength=0.7,moonStrength=0,ambientStrength=0.3,shadowsEnabled=true,shadowDistance=96,shadowCacheBounds={-144,-144,160,160},fogRange={80,0.025}}
    for n,v in pairs(textures) do uniforms[n]=v end
    for n,v in pairs(uniforms) do if shader:hasUniform(n) then shader:send(n,v) end end
    love.graphics.setCanvas(target);love.graphics.setBlendMode('replace','premultiplied');love.graphics.setShader(shader)
    love.graphics.rectangle('fill',0,0,96,64);love.graphics.setShader();love.graphics.setCanvas()
    return target:newImageData()
  end
  print('PASS: F5 toggle/repeat handling')
  local scenes={
    {'staircase',function() for y=0,31 do for x=-12,12 do column(x,y,{{0,2+math.floor(y/4)}}) end end end,5,-0.02},
    {'thin-grass-tops',function() for x=-12,12 do column(x,16,{{0,8}}) end end,8.02,0},
    {'mountain-ridge',function() for x=-32,32 do column(x,80,{{0,12+math.floor(8*math.sin(x*0.2))}}) end end,14,0},
    {'pillars-diagonal',function() for i=-8,8 do column(i*2,20+i,{{0,9}}) end end,7,0},
    {'cave-arch-ceiling',function() for x=-8,8 do for y=0,16 do column(x,y,math.abs(x)>5 and {{0,14}} or {{0,2},{10,14}}) end end end,6,0.15},
    {'water-boundary',function() for x=-10,10 do for y=0,20 do column(x,y,{{0,x<0 and 5 or 2}})
      local c=world.chunks[world:slot(math.floor(x/16),math.floor(y/16))];c.surface[(y%16)*16+x%16]=2048+4*8;c.maximum=math.max(c.maximum,5)
    end end end,6,-0.15}
  }
  local maxError,totalError,components=0,0,0
  for _,scene in ipairs(scenes) do
    reset(2);scene[2]();upload()
    local off=capture(stats,0,scene[3],scene[4],false)
    for y=0,63 do for x=0,95 do local groups,shadow,ao,rays=off:getPixel(x,y);assert(groups==1 and rays==1 and shadow<=1 and ao<=1,'Disabled AA still multisamples') end end
    off:release()
    for step=0,16 do
      local x=step/1024
      local a=capture(grouped,x,scene[3],scene[4]);local repeatFrame=capture(grouped,x,scene[3],scene[4])
      assert(a:getString()==repeatFrame:getString(),'Stationary frame changed: '..scene[1]);repeatFrame:release()
      local b=capture(independent,x,scene[3],scene[4]);local counts=capture(stats,x,scene[3],scene[4])
      for py=0,63 do for px=0,95 do
        local n,shadow,ao,rays=counts:getPixel(px,py);assert(n>=1 and n<=4 and rays==4 and shadow<=n and ao<=n,'Invalid sample counts')
        local ar,ag,ab=a:getPixel(px,py);local br,bg,bb=b:getPixel(px,py)
        for _,e in ipairs({math.abs(ar-br),math.abs(ag-bg),math.abs(ab-bb)}) do maxError=math.max(maxError,e);totalError=totalError+e;components=components+1 end
      end end
      if step==0 then local f=assert(io.open(os.getenv('SHADOW_OUTPUT')..'/'..scene[1]..'.png','wb'));local png=love.image.newImageData(96,64);png:mapPixel(function(x,y) return a:getPixel(x,y) end);f:write(png:encode('png'):getString());f:close();png:release() end
      a:release();b:release();counts:release()
    end
    print('PASS: '..scene[1]..', 17 tiny camera steps, deterministic repeats, four traces, bounded shade calls')
  end
  print(('Grouped versus independent shading: max RGB error %.9f, mean %.9f'):format(maxError,totalError/components))
end
function love.run()
  local ok,err=pcall(love.load);if world then world:stopWorker() end
  if not ok then print(err) end
  return function() return ok and 0 or 1 end
end
