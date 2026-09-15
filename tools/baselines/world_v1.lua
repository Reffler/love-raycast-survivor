-- Seeded block columns. Fixed ring cache; generation and uploads have bounded work.
local bit = require("bit")
local World = {}
World.__index = World
World.CHUNK = 16
World.MAX_HEIGHT = 32
local function hash(x,y,seed)
  local n=(x*374761393+y*668265263+seed*1447)%2147483647
  n=bit.bxor(n,bit.rshift(n,13))
  n=(n*16807)%2147483647
  n=bit.bxor(n,bit.rshift(n,11))
  n=(n*16807)%2147483647
  return n/2147483647
end
local function noise(x,y,seed)
  local ix,iy=math.floor(x),math.floor(y)
  local u,v=x-ix,y-iy
  u,v=u*u*(3-2*u),v*v*(3-2*v)
  local a,b=hash(ix,iy,seed),hash(ix+1,iy,seed)
  local c,d=hash(ix,iy+1,seed),hash(ix+1,iy+1,seed)
  return (a+(b-a)*u)*(1-v)+(c+(d-c)*u)*v
end
function World.new(seed,viewDistance)
  assert(type(seed)=='number' and seed==math.floor(seed) and math.abs(seed)<=2147483647,'Seed must be a signed 32-bit integer')
  local radius=math.ceil(viewDistance/World.CHUNK)+1
  return setmetatable({seed=seed,radius=radius,slots=radius*2+1,chunks={},queue={},head=1,generated=0},World)
end
function World:heightAt(x,y)
  return math.floor(4+18*noise(x/48,y/48,self.seed)+5*noise(x/17,y/17,self.seed+101))
end
function World:slot(cx,cy) return (cy%self.slots)*self.slots+cx%self.slots+1 end
function World:height(x,y)
  local cx,cy=math.floor(x/16),math.floor(y/16)
  local chunk=self.chunks[self:slot(cx,cy)]
  if chunk and chunk.x==cx and chunk.y==cy then return chunk.data[(y%16)*16+x%16+1] end
  return self:heightAt(x,y) -- Collision never waits for streaming.
end
function World:request(x,y)
  local cx,cy=math.floor(x/16),math.floor(y/16)
  if cx==self.cx and cy==self.cy then return end
  self.cx,self.cy=cx,cy
  self.queue,self.head,self.pending={},1,nil
  for dy=-self.radius,self.radius do for dx=-self.radius,self.radius do
    local tx,ty=cx+dx,cy+dy
    local chunk=self.chunks[self:slot(tx,ty)]
    if not chunk or chunk.x~=tx or chunk.y~=ty then
      self.queue[#self.queue+1]={x=tx,y=ty,distance=dx*dx+dy*dy}
    end
  end end
  table.sort(self.queue,function(a,b) return a.distance<b.distance end)
end
function World:step(budget,upload)
  local completed=0
  while budget>0 and self.head<=#self.queue do
    local chunk=self.pending
    if not chunk then
      local job=self.queue[self.head]
      chunk={x=job.x,y=job.y,data={},count=0,maximum=0}; self.pending=chunk
    end
    local count=math.min(budget,256-chunk.count)
    for i=chunk.count,chunk.count+count-1 do
      local height=self:heightAt(chunk.x*16+i%16,chunk.y*16+math.floor(i/16))
      chunk.data[i+1]=height
      chunk.maximum=math.max(chunk.maximum,height)
    end
    chunk.count=chunk.count+count; budget=budget-count
    if chunk.count==256 then
      if upload then upload(chunk) end
      self.chunks[self:slot(chunk.x,chunk.y)]=chunk
      self.generated=self.generated+1; completed=completed+1
      self.pending=nil; self.head=self.head+1
    end
  end
  return completed
end
function World:initGraphics(x,y)
  self.size=self.slots*16
  local data=love.image.newImageData(self.size,self.size,'r32f')
  self.imageData=data -- Keep reload source current across display-mode changes.
  self.texture=love.graphics.newImage(data,{linear=true,mipmaps=false})
  self.texture:setFilter('nearest','nearest')
  self.tile=love.image.newImageData(16,16,'r32f')
  self.maxData=love.image.newImageData(self.slots,self.slots,"r32f")
  self.maxTexture=love.graphics.newImage(self.maxData,{linear=true,mipmaps=false})
  self.maxTexture:setFilter("nearest","nearest")
  self.maxTile=love.image.newImageData(1,1,"r32f")
  self.upload=function(chunk)
    for i=0,255 do self.tile:setPixel(i%16,math.floor(i/16),chunk.data[i+1],0,0,1) end
    local x,y=(chunk.x%self.slots)*16,(chunk.y%self.slots)*16
    self.imageData:paste(self.tile,x,y,0,0,16,16)
    self.texture:replacePixels(self.tile,1,1,x,y)
    self.maxTile:setPixel(0,0,chunk.maximum,0,0,1)
    self.maxData:paste(self.maxTile,x/16,y/16,0,0,1,1)
    self.maxTexture:replacePixels(self.maxTile,1,1,x/16,y/16)
  end
  self:request(x,y)
  self:step(self.slots*self.slots*256,self.upload) -- Initial load, before first frame.
end
function World:update(x,y)
  self:request(x,y)
  if self.head>#self.queue then return end
  local deadline=love.timer.getTime()+0.00075
  local uploads=0
  repeat
    uploads=uploads+self:step(32,self.upload)
  until self.head>#self.queue or uploads>=2 or love.timer.getTime()>=deadline
end
return World
