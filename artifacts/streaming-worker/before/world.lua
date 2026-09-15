-- Fixed chunk pool and intrusive request queue: no movement-time table allocation.
local ffi,Terrain=require('ffi'),require('terrain')
local World={CHUNK=16,MAX_SPANS=4}
World.__index=World
function World.new(seed,viewDistance,terrainConfig)
  assert(type(seed)=='number' and seed==math.floor(seed) and math.abs(seed)<=2147483647,'Seed must be a signed 32-bit integer')
  assert(type(viewDistance)=='number' and viewDistance>=0 and viewDistance<math.huge,'View distance must be finite and nonnegative')
  local radius=math.ceil(viewDistance/16)+1
  local self=setmetatable({seed=seed,radius=radius,visibleDistance=viewDistance+2,slots=radius*2+1,chunks={},offsets={},edgeOrder={},
    first=0,last=0,pendingCount=0,generated=0,terrain=Terrain.new(seed,terrainConfig)},World)
  self.maxHeight=self.terrain.maxHeight;self.spanOverflowCount=0
  self.forceSpans=terrainConfig and terrainConfig.forceSpans or false
  for i=1,self.slots^2 do
    self.chunks[i]={data=ffi.new('uint16_t[256]'),spans=ffi.new('int16_t[2048]'),complex=false,surface=ffi.new('uint16_t[256]'),x=math.huge,y=math.huge,index=i,previous=0,next=0,queued=false,requestX=0,requestY=0,maximum=0}
  end
  for y=-radius,radius do for x=-radius,radius do
    self.offsets[#self.offsets+1]={x=x,y=y,distance=x*x+y*y}
  end end
  table.sort(self.offsets,function(a,b)
    if a.distance~=b.distance then return a.distance<b.distance end
    if a.x~=b.x then return a.x<b.x end
    return a.y<b.y
  end)
  self.edgeOrder[1]=0
  for i=1,radius do self.edgeOrder[#self.edgeOrder+1]=i;self.edgeOrder[#self.edgeOrder+1]=-i end
  return self
end
function World:slot(cx,cy) return (cy%self.slots)*self.slots+cx%self.slots+1 end
function World:heightAt(x,y) local h=self.terrain:height(x,y);return h end
function World:height(x,y)
  local cx,cy=math.floor(x/16),math.floor(y/16)
  local chunk=self.chunks[self:slot(cx,cy)]
  if chunk.x==cx and chunk.y==cy then return tonumber(chunk.data[(y%16)*16+x%16]) end
  local h=self.terrain:height(x,y) -- Collision fallback never modifies the streaming queue.
  return h
end
-- Cached queries borrow span buffers; fallback is analytic and never alters streaming queue.
function World:columnSpans(x,y)
  x,y=math.floor(x),math.floor(y)
  local cx,cy=math.floor(x/16),math.floor(y/16);local c=self.chunks[self:slot(cx,cy)]
  if c.x==cx and c.y==cy then
    local i=(y%16)*16+x%16;local k=i*8
    if c.complex and c.spans[k+2]<0 then return c.spans,k,false,c.spans[k+1] end
    return c.spans,k,c.complex,c.data[i]
  end
  local spans,_,complex=self.terrain:spansAt(x,y)
  self.spanOverflowCount=self.terrain.spanOverflowCount
  return spans,0,complex,spans[1]
end
function World:isSolid(x,y,z)
  local spans,k,complex,h=self:columnSpans(x,y)
  if not complex then return z>=0 and z<h end
  for j=0,3 do local lo,hi=spans[k+j*2],spans[k+j*2+1];if lo<0 then break end;if z>=lo and z<hi then return true end end
  return false
end
function World:floorBelow(x,y,z)
  local spans,k,complex,h=self:columnSpans(x,y)
  if not complex then return h<=z and tonumber(h) or nil end
  local result=nil
  for j=0,3 do local lo,hi=spans[k+j*2],spans[k+j*2+1];if lo<0 then break end;if hi<=z then result=tonumber(hi) end end
  return result
end
function World:ceilingAbove(x,y,z)
  local spans,k,complex,h=self:columnSpans(x,y)
  if not complex then return z<=0 and 0 or nil end
  for j=0,3 do local lo=spans[k+j*2];if lo<0 then break end;if lo>=z then return tonumber(lo) end end
end
function World:overlaps(x,y,lo,hi)
  local spans,k,complex,h=self:columnSpans(x,y)
  if not complex then return lo<h-0.00001 and hi>0.00001 end
  for j=0,3 do
    local a,b=spans[k+j*2],spans[k+j*2+1];if a<0 then break end
    if lo<b-0.00001 and hi>a+0.00001 then return true end
  end
  return false
end
-- Returned chunk is borrowed from fixed pool; valid until its slot is reused.
function World:generateChunk(cx,cy)
  local chunk=self.chunks[self:slot(cx,cy)]
  chunk.maximum,chunk.complex=self.terrain:generate(cx,cy,chunk.data,chunk.surface,chunk.spans)
  chunk.complex=chunk.complex or self.forceSpans
  if self.forceSpans then
    ffi.fill(chunk.spans,4096,255)
    for i=0,255 do chunk.spans[i*8]=0;chunk.spans[i*8+1]=chunk.data[i] end
  end
  chunk.x,chunk.y=cx,cy
  self.spanOverflowCount=self.terrain.spanOverflowCount
  self.generated=self.generated+1
  return chunk
end
function World:removeRequest(chunk)
  if not chunk.queued then return end
  if chunk.previous~=0 then self.chunks[chunk.previous].next=chunk.next else self.first=chunk.next end
  if chunk.next~=0 then self.chunks[chunk.next].previous=chunk.previous else self.last=chunk.previous end
  chunk.queued=false;self.pendingCount=self.pendingCount-1
end
function World:enqueue(cx,cy)
  local chunk=self.chunks[self:slot(cx,cy)]
  if chunk.queued and chunk.requestX==cx and chunk.requestY==cy then return end
  self:removeRequest(chunk)
  if chunk.x==cx and chunk.y==cy then return end
  chunk.requestX,chunk.requestY=cx,cy
  chunk.previous,chunk.next,chunk.queued=self.last,0,true
  if self.last~=0 then self.chunks[self.last].next=chunk.index else self.first=chunk.index end
  self.last=chunk.index;self.pendingCount=self.pendingCount+1
end
function World:request(x,y)
  local cx,cy=math.floor(x/16),math.floor(y/16)
  if cx==self.cx and cy==self.cy then return end
  local dx,dy=cx-(self.cx or cx),cy-(self.cy or cy)
  if not self.cx or math.abs(dx)>1 or math.abs(dy)>1 then
    while self.first~=0 do self:removeRequest(self.chunks[self.first]) end
    for i=1,#self.offsets do
      local offset=self.offsets[i];self:enqueue(cx+offset.x,cy+offset.y)
    end
  else
    -- Only incoming strips; retained requests keep their place in queue.
    if dx~=0 then for i=1,self.slots do self:enqueue(cx+dx*self.radius,cy+self.edgeOrder[i]) end end
    if dy~=0 then for i=1,self.slots do
      local x=cx+self.edgeOrder[i]
      if dx==0 or x~=cx+dx*self.radius then self:enqueue(x,cy+dy*self.radius) end
    end end
  end
  self.cx,self.cy=cx,cy
end
function World:hasPending() return self.first~=0 end
-- Budget remains in columns for harness compatibility; chunks are never partial.
function World:step(budget,upload)
  local completed=0
  while budget>=256 and self.first~=0 do
    local chunk=self.chunks[self.first]
    local cx,cy=chunk.requestX,chunk.requestY
    if self.streaming and not self.terrain:ready(cx,cy) then
      local remaining=math.min(0.0002,math.max(0,self.deadline-love.timer.getTime()))
      if remaining>0 then self.terrain:advance(remaining) end
      break
    end
    self:removeRequest(chunk)
    chunk=self:generateChunk(cx,cy)
    if upload then upload(chunk) end
    budget=budget-256;completed=completed+1
  end
  return completed
end
function World:releaseGraphics()
  for _,name in ipairs({'texture','imageData','tile','maxTexture','maxData','maxTile','spanTex0','spanTex1','spanData0','spanData1','spanTile0','spanTile1'}) do
    if self[name] then self[name]:release();self[name]=nil end
  end
end
function World:initGraphics(x,y,format)
  self:releaseGraphics()
  self.size=self.slots*16
  self.format=format or 'r16f'
  assert(self.format=='r16f' or self.format=='r32f','Height format must be r16f or r32f')
  self.imageData=love.image.newImageData(self.size,self.size,self.format=='r16f' and 'rg16f' or 'rg32f')
  self.texture=love.graphics.newImage(self.imageData,{linear=true,mipmaps=false})
  self.texture:setFilter('nearest','nearest')
  self.tile=love.image.newImageData(16,16,self.format=='r16f' and 'rg16f' or 'rg32f')
  self.maxData=love.image.newImageData(self.slots,self.slots,self.format)
  self.maxTexture=love.graphics.newImage(self.maxData,{linear=true,mipmaps=false})
  self.maxTexture:setFilter('nearest','nearest')
  self.maxTile=love.image.newImageData(1,1,self.format)
  self.spanData0=love.image.newImageData(self.size,self.size,'rgba16f')
  self.spanData1=love.image.newImageData(self.size,self.size,'rgba16f')
  self.spanTex0=love.graphics.newImage(self.spanData0,{linear=true,mipmaps=false})
  self.spanTex1=love.graphics.newImage(self.spanData1,{linear=true,mipmaps=false})
  self.spanTex0:setFilter('nearest','nearest');self.spanTex1:setFilter('nearest','nearest')
  self.spanTile0=love.image.newImageData(16,16,'rgba16f')
  self.spanTile1=love.image.newImageData(16,16,'rgba16f')
  -- Hardware wrapping replaces per-sample modulo in the raycaster.
  for _,texture in ipairs({self.texture,self.maxTexture,self.spanTex0,self.spanTex1}) do texture:setWrap('repeat','repeat') end
  local sp0=ffi.cast('uint16_t*',self.spanTile0:getFFIPointer())
  local sp1=ffi.cast('uint16_t*',self.spanTile1:getFFIPointer())
  local spanEncoded=ffi.new('uint16_t[256]')
  for h=1,255 do local _,e=math.frexp(h);spanEncoded[h]=(e+14)*1024+(h/2^(e-1)-1)*1024 end
  local half=self.format=='r16f'
  local pixels=ffi.cast(half and 'uint16_t*' or 'float*',self.tile:getFFIPointer())
  local maxPixel=ffi.cast(half and 'uint16_t*' or 'float*',self.maxTile:getFFIPointer())
  local encoded=ffi.new(half and 'uint16_t[2049]' or 'float[2049]')
  for h=1,2048 do
    local _,e=math.frexp(h)
    encoded[h]=half and (e+14)*1024+(h/2^(e-1)-1)*1024 or h
  end
  self.upload=function(chunk)
    for i=0,255 do pixels[i*2]=encoded[chunk.data[i]*8+math.floor(chunk.surface[i]/2048)];pixels[i*2+1]=encoded[chunk.surface[i]%2048] end
    local x,y=(chunk.x%self.slots)*16,(chunk.y%self.slots)*16
    self.imageData:paste(self.tile,x,y,0,0,16,16) -- Preserve CPU source for display-mode reload.
    self.texture:replacePixels(self.tile,1,1,x,y)
    if chunk.complex then
      for i=0,255 do for j=0,3 do
        local a,b=chunk.spans[i*8+j],chunk.spans[i*8+j+4]
        sp0[i*4+j]=a<0 and 48128 or spanEncoded[a]
        sp1[i*4+j]=b<0 and 48128 or spanEncoded[b]
      end end
      self.spanData0:paste(self.spanTile0,x,y,0,0,16,16);self.spanData1:paste(self.spanTile1,x,y,0,0,16,16)
      self.spanTex0:replacePixels(self.spanTile0,1,1,x,y);self.spanTex1:replacePixels(self.spanTile1,1,1,x,y)
    end
    maxPixel[0]=encoded[chunk.maximum+(chunk.complex and 512 or 0)]
    self.maxData:paste(self.maxTile,x/16,y/16,0,0,1,1)
    self.maxTexture:replacePixels(self.maxTile,1,1,x/16,y/16)
  end
  self:request(x,y)
  for i=1,#self.chunks do
    local chunk=self.chunks[i]
    if math.abs(chunk.x-self.cx)<=self.radius and math.abs(chunk.y-self.cy)<=self.radius then self.upload(chunk) end
  end
  self:step(self.slots^2*256,self.upload)
end
function World:bindSpans(shader)
  if shader:hasUniform('spanTex0') then shader:send('spanTex0',self.spanTex0);shader:send('spanTex1',self.spanTex1) end
end
function World:update(x,y)
  self:request(x,y)
  if self.first==0 then return end
  -- Never render recycled slots from behind the player. Include AO/water neighbors
  -- and camera interpolation; only offscreen prefetch may miss its time budget.
  local index=self.first
  while index~=0 do
    local chunk=self.chunks[index];index=chunk.next
    local cx,cy=chunk.requestX,chunk.requestY
    local dx=math.max(cx*16-x,0,x-(cx+1)*16)
    local dy=math.max(cy*16-y,0,y-(cy+1)*16)
    if dx*dx+dy*dy<=self.visibleDistance^2 then
      self:removeRequest(chunk)
      chunk=self:generateChunk(cx,cy)
      if self.upload then self.upload(chunk) end
    end
  end
  if self.first==0 then return end
  self.streaming=true
  local deadline=love.timer.getTime()+0.00075
  self.deadline=deadline
  local uploads=0
  repeat
    uploads=uploads+self:step(256,self.upload)
  until self.first==0 or uploads>=2 or love.timer.getTime()>=deadline
  self.streaming=false
end
return World
