local originalLoad=love.load
function love.load()
  originalLoad();CONFIG.DEBUG_ENABLED=false
  love.window.setMode(1920,1080,{fullscreen=false,vsync=0});love.resize(love.graphics.getDimensions())
  local modern=raycastShader
  local source=assert(love.filesystem.read('raycast.glsl'))
  local legacy=love.graphics.newShader('#define MAX_DDA_STEPS '..MAX_DDA_STEPS..'\n'..assert(love.filesystem.read('legacy.glsl')))
  local function selectShader(s)
    raycastShader=s;lastRot,lastPitch=nil,nil;updateProjection(love.graphics.getDimensions())
    s:send('heightTex',world.texture);s:send('chunkMaxTex',world.maxTexture)
    s:send('cacheSize',world.size);s:send('maxHeight',world.maxHeight);s:send('viewDist',CONFIG.VIEW_DIST)
  end
  local function frame()
    love.draw();local d=renderCanvas:newImageData();d:release()
  end
  local function camera(x,y,z,angle,tilt)
    px,py,eyeHeight=x,y,z;rot,pitch=angle,tilt
    previousPx,previousPy,previousEyeHeight=px,py,eyeHeight;eyeStepOffset,previousEyeStepOffset=0,0;physicsAccumulator=0
  end
  local function measure(name,s)
    selectShader(s);for i=1,30 do frame() end
    local times={};for i=1,240 do local t=love.timer.getTime();frame();times[i]=(love.timer.getTime()-t)*1000 end
    table.sort(times);print(('RENDER,%s,median_ms,%.4f,p99_ms,%.4f'):format(name,times[120],times[238]))
  end
  world:releaseGraphics();world=World.new(1337,CONFIG.VIEW_DIST,{caves=false});world:initGraphics(0,0)
  camera(3.5,3.5,world:height(3,3)+1.62,0,0)
  measure('ordinary_legacy',legacy);measure('ordinary_spans_shader',modern)
  world:releaseGraphics();world=World.new(1337,CONFIG.VIEW_DIST);world:initGraphics(0,0)
  local node
  local region=world.terrain.regions:get(0,0)
  for _,n in pairs(region.caveNodes) do if n.active and n.x>=0 and n.x<1024 and n.y>=0 and n.y<1024 and (not node or n.radius>node.radius) then node=n end end
  assert(node,'Missing cave benchmark node')
  world:request(node.x,node.y);while world:hasPending() do world:step(256,world.upload) end
  camera(node.x,node.y,node.z,0,-0.1)
  local complex=0;for _,c in ipairs(world.chunks) do if c.complex then complex=complex+1 end end
  local pages=math.ceil(math.sqrt(complex));local size=pages*16
  local start=love.timer.getTime()
  local data0,data1=love.image.newImageData(size,size,'rgba16f'),love.image.newImageData(size,size,'rgba16f')
  local mapping=love.image.newImageData(world.slots,world.slots,'r32f');local page=0
  for _,c in ipairs(world.chunks) do if c.complex then
    local x,y=(c.x%world.slots)*16,(c.y%world.slots)*16
    data0:paste(world.spanData0,(page%pages)*16,math.floor(page/pages)*16,x,y,16,16)
    data1:paste(world.spanData1,(page%pages)*16,math.floor(page/pages)*16,x,y,16,16)
    mapping:setPixel(x/16,y/16,page,0,0,1);page=page+1
  end end
  local atlas0,atlas1,map=love.graphics.newImage(data0,{linear=true}),love.graphics.newImage(data1,{linear=true}),love.graphics.newImage(mapping,{linear=true})
  atlas0:setFilter('nearest','nearest');atlas1:setFilter('nearest','nearest');map:setFilter('nearest','nearest')
  local build=(love.timer.getTime()-start)*1000
  local sparse=source:gsub('extern Image spanTex0;','extern Image spanTex0;\nextern Image spanPageTex;\nextern float spanAtlasSize;')
  sparse=sparse:gsub('bool complexChunk=false;','bool complexChunk=false;vec2 spanBase=vec2(0.0);')
  sparse=sparse:gsub('previousChunk=chunk;',[[if (complexChunk) {
    float page=Texel(spanPageTex,(mod(chunk+cacheOffset/16.0,cacheSize/16.0)+0.5)/(cacheSize/16.0)).r;
    spanBase=vec2(mod(page,spanAtlasSize/16.0),floor(page/(spanAtlasSize/16.0)))*16.0;
  }
  previousChunk=chunk;]])
  local old='vec2 uv=(mod(cell+cacheOffset,cacheSize)+0.5)/cacheSize;'
  local a,b=sparse:find(old,1,true);assert(a);sparse=sparse:sub(1,a-1)..'vec2 uv=(spanBase+mod(cell,16.0)+0.5)/spanAtlasSize;'..sparse:sub(b+1)
  local sparseShader=love.graphics.newShader('#define MAX_DDA_STEPS '..MAX_DDA_STEPS..'\n'..sparse)
  sparseShader:send('spanPageTex',map);sparseShader:send('spanAtlasSize',size)
  local bind=world.bindSpans
  world.bindSpans=function(self,s)
    if s==sparseShader then s:send('spanTex0',atlas0);s:send('spanTex1',atlas1) else bind(self,s) end
  end
  selectShader(modern);love.draw();local a=renderCanvas:newImageData()
  selectShader(sparseShader);love.draw();local b=renderCanvas:newImageData()
  assert(a:getString()==b:getString(),'Sparse/fixed framebuffer differs');a:release();b:release()
  measure('cave_fixed',modern);measure('cave_sparse',sparseShader)
  camera(node.x,node.y,world:height(math.floor(node.x),math.floor(node.y))+30,0,-0.25)
  measure('outdoor_complex_fixed',modern);measure('outdoor_complex_sparse',sparseShader)
  print(('STORAGE,resident_chunks,%d,complex_chunks,%d,fixed_gpu_mib,%.4f,sparse_gpu_mib,%.4f,cpu_span_mib,%.4f,sparse_pack_upload_ms,%.3f'):format(#world.chunks,complex,world.size^2*16/2^20,(size^2*16+world.slots^2*4)/2^20,#world.chunks*4096/2^20,build))
end
function love.run()
  local ok,err=pcall(love.load);if not ok then print(err) end
  return function() return ok and 0 or 1 end
end
