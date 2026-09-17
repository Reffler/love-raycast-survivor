local originalLoad=love.load
function love.load()
  originalLoad();CONFIG.DEBUG_ENABLED=false
  local productionShader=raycastShader
  local ffi=require('ffi')
  local source=love.filesystem.read('raycast.glsl')
  local prefix='#pragma language glsl3\n#define MAX_DDA_STEPS '..MAX_DDA_STEPS..'\n'..source:sub(1,assert(source:find('vec4 effect(',1,true))-1)
  local body=[[
    extern vec3 testOrigin;extern vec3 testU;extern vec3 testV;extern vec3 testNormal;extern float testScale;
    vec4 effect(vec4 c,Image t,vec2 tc,vec2 sc) {
      vec3 p=shadowReceiver(testOrigin+testU*sc.x/testScale+testV*sc.y/testScale,testNormal);
      float visibility=sunVisibility(p,sunDirection);
#ifdef SHADOW_STATS
      return shadowCounters;
#else
      return vec4(visibility,p);
#endif
    }
  ]]
  local probe=love.graphics.newShader(prefix..body)
  local diagnostic=love.graphics.newShader('#pragma language glsl3\n#define SHADOW_STATS\n'..prefix..body)
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
  local function normalize(x,y,z) local l=math.sqrt(x*x+y*y+z*z);return {x/l,y/l,z/l} end
  local function bind(s)
    for name,value in pairs({heightTex=world.texture,chunkMaxTex=world.maxTexture,spanTex0=world.spanTex0,spanTex1=world.spanTex1,cacheSize=world.size,cacheOffset={0,0},maxHeight=32,shadowDistance=96,shadowCacheBounds={-144,-144,160,160}}) do
      if s:hasUniform(name) then s:send(name,value) end
    end
  end
  local function capture(s,origin,u,v,n,sun,size,scale,options)
    bind(s)
    s:send('testOrigin',origin);s:send('testU',u);s:send('testV',v);s:send('testNormal',n);s:send('testScale',scale or 16);s:send('sunDirection',sun)
    for name,value in pairs(options or {}) do if s:hasUniform(name) then s:send(name,value) end end
    local target=love.graphics.newCanvas(size or 64,size or 64,{format='rgba32f',dpiscale=1})
    love.graphics.setCanvas(target);love.graphics.setBlendMode('replace','premultiplied');love.graphics.setShader(s)
    love.graphics.rectangle('fill',0,0,size or 64,size or 64)
    love.graphics.setShader();love.graphics.setCanvas()
    local data=target:newImageData();target:release();return data
  end
  -- Independent analytic ray/AABB reference; no shader DDA logic duplicated here.
  local function visible(p,sun,distance,maxHeight)
    local limit=math.min(distance or 96,math.max(0,((maxHeight or 32)-p[3])/sun[3]))
    for _,box in ipairs(boxes) do
      local lo,hi=0,limit
      for axis=1,3 do
        if math.abs(sun[axis])<1e-12 then
          if p[axis]<=box[axis] or p[axis]>=box[axis+3] then hi=-1 end
        else
          local a,b=(box[axis]-p[axis])/sun[axis],(box[axis+3]-p[axis])/sun[axis]
          lo=math.max(lo,math.min(a,b));hi=math.min(hi,math.max(a,b))
        end
      end
      if hi>lo+1e-6 then return 0 end
    end
    return 1
  end
  local function check(name,origin,u,v,n,sun,options)
    local data=capture(probe,origin,u,v,n,sun,64,16,options)
    local lit,dark=0,0
    for y=0,63 do for x=0,63 do
      local vis,px,py,pz=data:getPixel(x,y)
      assert(vis==0 or vis==1,'Nonbinary shadow')
      local expected=visible({px,py,pz},sun,options and options.shadowDistance,options and options.maxHeight)
      assert(vis==expected,('%s mismatch at %d,%d: got %g expected %g'):format(name,x,y,vis,expected))
      if vis==1 then lit=lit+1 else dark=dark+1 end
    end end
    data:release();return lit,dark
  end
  local sun=normalize(0.6,0.3,0.74)
  reset(4)
  for x=3,4 do for y=1,4 do column(x,y,{{0,8}}) end end
  upload()
  local lit,dark=check('diagonal-top',{0,0,4},{1,0,0},{0,1,0},{0,0,1},sun)
  assert(lit>0 and dark>0,'Diagonal fixture lacks shadow edge')
  -- Translate within each texel: identical visibility despite different high-resolution hits.
  local a=capture(probe,{0,0,4},{1,0,0},{0,1,0},{0,0,1},sun)
  local b=capture(probe,{0.01,0.01,4},{1,0,0},{0,1,0},{0,0,1},sun)
  for y=0,63 do for x=0,63 do assert(a:getPixel(x,y)==b:getPixel(x,y),'Subtexel translation moved shadow') end end
  a:release();b:release()
  -- Oversampled face images: every 4x4 screen group maps to one world texel.
  local first,last
  for frame=0,8 do
    local movingSun=normalize(0.6,0.3+frame*0.003,0.74)
    local data=capture(probe,{0,0,4},{1,0,0},{0,1,0},{0,0,1},movingSun,256,64)
    for y=0,255 do for x=0,255 do
      assert(data:getPixel(x,y)==data:getPixel(math.floor(x/4)*4,math.floor(y/4)*4),'Sun motion split a texture texel')
    end end
    if frame==0 then first=data else if last then last:release() end;last=data end
  end
  local changed=0
  for y=0,255 do for x=0,255 do if first:getPixel(x,y)~=last:getPixel(x,y) then changed=changed+1 end end end
  assert(changed>0 and changed%16==0,'Moving sun did not advance whole texels')
  local function saveMask(data,name)
    local out=love.image.newImageData(data:getWidth(),data:getHeight())
    for y=0,data:getHeight()-1 do for x=0,data:getWidth()-1 do
      local light=0.28+0.72*data:getPixel(x,y);out:setPixel(x,y,0.32*light,0.62*light,0.18*light,1)
    end end
    local file=assert(io.open(os.getenv('SHADOW_OUTPUT')..'/'..name..'.png','wb'));file:write(out:encode('png'):getString());file:close();out:release()
  end
  saveMask(first,'top-texels-before');saveMask(last,'top-texels-after');first:release();last:release()
  love.window.setMode(960,720,{vsync=0});love.resize(960,720)
  raycastShader=productionShader;lastRot,lastPitch=nil,nil;updateProjection(960,720)
  for name,value in pairs({heightTex=world.texture,chunkMaxTex=world.maxTexture,cacheSize=world.size,maxHeight=world.maxHeight,viewDist=128}) do productionShader:send(name,value) end
  for i=0,1 do
    px,py,eyeHeight=1.4+i*0.01,0.7,6;previousPx,previousPy,previousEyeHeight=px,py,eyeHeight
    rot,pitch=0,-math.pi/2;eyeStepOffset,previousEyeStepOffset,physicsAccumulator=0,0,0
    love.draw();local data=renderCanvas:newImageData()
    local file=assert(io.open(os.getenv('SHADOW_OUTPUT')..'/grass-locked-'..i..'.png','wb'))
    file:write(data:encode('png'):getString());file:close();data:release()
  end
  -- Use the actual primary camera traversal, recording snapped world receiver + visibility.
  local cameraSource=source:gsub('return vec4%(color,1.0%);','return vec4(0.0,0.0,0.0,-1.0);')
  cameraSource=cameraSource:gsub('return vec4%(atmosphericColor%(shaded,ray,solidHit%),1.0%);','return vec4(shadowReceiver(hit,solidNormal),visibility);')
  local cameraProbe=love.graphics.newShader('#pragma language glsl3\n#define MAX_DDA_STEPS '..MAX_DDA_STEPS..'\n'..cameraSource)
  love.window.setMode(320,240,{vsync=0});love.resize(320,240)
  renderCanvas:release();renderCanvas=love.graphics.newCanvas(320,240,{format='rgba32f',dpiscale=1})
  raycastShader=cameraProbe;lastRot,lastPitch=nil,nil;updateProjection(320,240)
  for name,value in pairs({heightTex=world.texture,chunkMaxTex=world.maxTexture,cacheSize=world.size,maxHeight=world.maxHeight,viewDist=128}) do if cameraProbe:hasUniform(name) then cameraProbe:send(name,value) end end
  local samples={};local shared=0
  for i,p in ipairs({{-0.005,-2,10,90},{0.005,-2,10,90},{0.005,-2,10,90.2}}) do
    px,py,eyeHeight=p[1],p[2],p[3];rot,pitch=math.rad(p[4]),math.rad(-55)
    previousPx,previousPy,previousEyeHeight=px,py,eyeHeight;eyeStepOffset,previousEyeStepOffset,physicsAccumulator=0,0,0
    love.draw();local data=renderCanvas:newImageData()
    local ox,oy=math.floor(px/16)*16,math.floor(py/16)*16
    for y=0,239 do for x=0,319 do
      local sx,sy,sz,vis=data:getPixel(x,y)
      if vis>=0 then
        local key=('%.3f,%.3f,%.3f'):format(sx+ox,sy+oy,sz)
        if samples[key]~=nil then assert(samples[key]==vis,'Camera motion/rebase changed world-texel shadow');if i>1 then shared=shared+1 end end
        samples[key]=vis
      end
    end end
    data:release()
  end
  assert(shared>1000,'Insufficient shared camera texels')
  print(('PASS: diagonal top shadows, 0.01-block translation across origin rebase, camera rotation (%d shared samples), continuous sun moves whole texels'):format(shared))
  for _,axis in ipairs({1,2}) do for _,sign in ipairs({-1,1}) do
    reset(0)
    local function reflect(cell) return sign<0 and cell or -cell-1 end
    for a=0,4 do
      if axis==1 then column(reflect(5),a,{{0,10}}) else column(a,reflect(5),{{0,10}}) end
      if a<=2 then for b=1,2 do if axis==1 then column(reflect(b),a,{{0,8}}) else column(a,reflect(b),{{0,8}}) end end end
    end
    upload()
    local origin=axis==1 and {-sign*5,0,2} or {0,-sign*5,2}
    local u=axis==1 and {0,1,0} or {1,0,0}
    local n=axis==1 and {sign,0,0} or {0,sign,0}
    local direction=axis==1 and normalize(sign*0.6,0.3,0.74) or normalize(0.3,sign*0.6,0.74)
    local l,d=check('wall-'..axis,origin,u,{0,0,1},n,direction);assert(l>0 and d>0,'Wall lacks diagonal edge')
    local image=capture(probe,origin,u,{0,0,1},n,direction,256,64);saveMask(image,'wall-'..axis..'-'..sign..'-texels');image:release()
  end end
  reset(4)
  for x=0,3 do for y=0,3 do column(x,y,{{0,4},{8,9},{12,13},{16,17}}) end end
  upload()
  lit,dark=check('four-span-ceiling',{0,0,4},{1,0,0},{0,1,0},{0,0,1},{0,0,1});assert(dark==4096,'Vertical roof ray leaked')
  for x=1,2 do for y=1,2 do column(x,y,{{0,4}}) end end
  -- Rebuild CPU reference from the final column set (removed roofs must not remain).
  boxes={}
  for x=0,3 do for y=0,3 do
    if x==0 or x==3 or y==0 or y==3 then
      for _,bounds in ipairs({{0,4},{8,9},{12,13},{16,17}}) do boxes[#boxes+1]={x,y,bounds[1],x+1,y+1,bounds[2]} end
    end
  end end
  upload();lit,dark=check('roof-opening',{0,0,4},{1,0,0},{0,1,0},{0,0,1},{0,0,1})
  assert(lit==1024 and dark==3072,'Opening/arch shadow wrong')
  -- Negative seams, nearly vertical rays, finite range, above-world termination.
  reset(0);column(-17,-1,{{0,4},{8,12}});upload()
  check('negative-chunk-seam',{-20,-3,4},{1,0,0},{0,1,0},{0,0,1},sun)
  reset(4);column(3,0,{{0,20}});upload()
  check('short-range',{0,0,4},{1,0,0},{0,1,0},{0,0,1},sun,{shadowDistance=1})
  local data=capture(diagnostic,{0,0,40},{1,0,0},{0,1,0},{0,0,1},sun,1)
  local cells,skips,reason=data:getPixel(0,0);assert(cells==0 and reason==4,'Above-world ray did work');data:release()
  reset(4);upload()
  data=capture(diagnostic,{0,0,4},{1,0,0},{0,1,0},{0,0,1},sun,1)
  cells,skips,reason=data:getPixel(0,0);assert(cells==0 and skips>0,'Empty high chunks not skipped');data:release()
  -- Explicit bounds and invalid metadata stop before wrapped or pending slot reads.
  data=capture(diagnostic,{159,0,4},{1,0,0},{0,1,0},{0,0,1},normalize(0.9,0,0.3),1)
  cells,skips,reason=data:getPixel(0,0);assert(reason==6,'Cache bound not enforced');data:release()
  world.maxData:setPixel(0,0,1024,0,0,1);world.maxTexture:replacePixels(world.maxData)
  data=capture(diagnostic,{0,0,4},{1,0,0},{0,1,0},{0,0,1},sun,1)
  cells,skips,reason=data:getPixel(0,0);assert(cells==0 and reason==7,'Pending slot was sampled');data:release()
  upload()
  local cx,cy=world.cx,world.cy
  world:request(16,0)
  local pending=world.chunks[world.first];local slotX,slotY=pending.requestX%world.slots,pending.requestY%world.slots
  assert(world.maxData:getPixel(slotX,slotY)==1024,'Incoming slot not invalidated')
  world:request(0,0)
  local retained=world.chunks[slotY*world.slots+slotX+1]
  assert(world.maxData:getPixel(slotX,slotY)==retained.maximum+(retained.complex and 512 or 0),'Reversal did not restore retained metadata')
  print('PASS: X/Y wall grids, four solid spans, vertical cave roofs/openings, negative seams, distance limit, ceiling termination, chunk skipping, cache bounds, invalid slots and reversal')
  local fullStats=love.graphics.newShader('#pragma language glsl3\n#define SHADOW_STATS\n#define MAX_DDA_STEPS '..MAX_DDA_STEPS..'\n'..source)
  local function primary(s,z,tilt)
    raycastShader=s;lastRot,lastPitch=nil,nil;updateProjection(320,240)
    for name,value in pairs({heightTex=world.texture,chunkMaxTex=world.maxTexture,cacheSize=world.size,maxHeight=world.maxHeight,viewDist=128}) do if s:hasUniform(name) then s:send(name,value) end end
    px,py,eyeHeight=0.5,0.5,z;previousPx,previousPy,previousEyeHeight=px,py,eyeHeight;rot,pitch=0,tilt
    love.draw();return renderCanvas:newImageData()
  end
  reset(4);upload()
  for _,degrees in ipairs({-90,-60,-20,-15,-11.9,-10,0,10,11.9,15,60,90}) do
    dayPhase=degrees/360;CONFIG.SHADOWS_ENABLED=true
    local data=primary(fullStats,5,-math.pi/2)
    local cells,skipped,reason=data:getPixel(160,120)
    if math.abs(degrees)<=11.9 then assert(cells==0 and skipped==0 and reason<=2,'Low sun cast a ray')
    else assert(reason>=3,'High sun failed to cast') end
    data:release()
  end
  dayPhase=1/6;CONFIG.SHADOWS_ENABLED=false
  data=primary(fullStats,5,-math.pi/2);cells,skips,reason=data:getPixel(160,120)
  assert(cells==0 and skips==0 and reason==2,'Disabled shadows cast a ray');data:release()
  CONFIG.SHADOWS_ENABLED=true
  for x=-1,2 do for y=-1,2 do column(x,y,{{0,4},{8,9}}) end end;upload()
  data=primary(fullStats,6,math.pi/2);cells,skips,reason=data:getPixel(160,120)
  assert(cells==0 and skips==0 and reason==1,'Back-facing ceiling cast a ray');data:release()
  dayPhase=0.75
  data=primary(fullStats,6,math.pi/2);cells,skips,reason=data:getPixel(160,120)
  assert(cells==0 and skips==0 and reason==1,'Moon back-facing ceiling cast a ray');data:release()
  data=primary(fullStats,6,-math.pi/2);cells,skips,reason=data:getPixel(160,120)
  assert(cells>0 and reason==5,'Moonlight leaked through cave roof');data:release()
  CONFIG.SHADOWS_ENABLED=false
  data=primary(fullStats,6,-math.pi/2);cells,skips,reason=data:getPixel(160,120)
  assert(cells==0 and reason==2,'Disabled moon shadows cast a ray');data:release()
  CONFIG.SHADOWS_ENABLED=true;dayPhase=1/6
  print('PASS: moon shadows block cave roofs; moon backfaces, toggle and low-elevation cutoff')
  reset(4)
  for _,c in ipairs(world.chunks) do c.maximum=8;for i=0,255 do c.surface[i]=64 end end
  upload()
  data=primary(fullStats,10,-math.pi/2)
  for y=0,239 do for x=0,319 do
    local cells,skips,reason=data:getPixel(x,y);assert(cells==0 and skips==0 and reason==0,'Water received a shadow ray')
  end end;data:release()
  data=capture(probe,{0,0,4},{1,0,0},{0,1,0},{0,0,1},sun)
  for y=0,63 do for x=0,63 do assert(data:getPixel(x,y)==1,'Water cast a solid shadow') end end;data:release()
  CONFIG.SHADOWS_ENABLED=false;data=primary(productionShader,10,-math.pi/2);local waterPixels=data:getString();data:release()
  CONFIG.SHADOWS_ENABLED=true;data=primary(productionShader,10,-math.pi/2)
  assert(data:getString()==waterPixels,'Water changed with shadow toggle');data:release()
  print('PASS: low-sun cutoff, continuous daylight range, toggle, back-facing ceilings skip rays; water neither receives nor casts shadows')
end
function love.run()
  local ok,err=pcall(love.load);world:stopWorker()
  if not ok then print(err) end
  return function() return ok and 0 or 1 end
end
