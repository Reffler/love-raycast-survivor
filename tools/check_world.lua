local ffi=require('ffi')
local World,Terrain=require('world'),require('terrain')
local world=World.new(1337,256)
local other=World.new(42,48)
local same=World.new(1337,48)
local changed=false
-- Full chunk samples match independent scalar evaluation, including negative seams.
for cy=-10,10 do for cx=-10,10 do
  local chunk=world:generateChunk(cx,cy);local maximum=0
  assert(ffi.sizeof(chunk.data)==512,'Chunk heights are not compact uint16 storage')
  for j=0,15 do for i=0,15 do
    local x,y=cx*16+i,cy*16+j;local h=tonumber(chunk.data[j*16+i])
    assert(h==world:heightAt(x,y) and h==same:heightAt(x,y),'Bulk/scalar disagreement')
    assert(h>=0 and h<=world.maxHeight and h==math.floor(h))
    local top=h
    if chunk.complex then for span=0,3 do local hi=chunk.spans[(j*16+i)*8+span*2+1];if hi>=0 then top=hi end end end
    maximum=math.max(maximum,top,math.ceil((chunk.surface[j*16+i]%2048)/8));changed=changed or h~=other:heightAt(x,y)
  end end
  assert(chunk.maximum==maximum,'Incorrect chunk maximum')
end end
assert(changed,'Seeds produce identical terrain')
-- Lattice-aligned controls must be continuous from either side of chunk boundaries.
for _,name in ipairs({'SEA_LEVEL','OCEAN_FLOOR','CONTINENT_SCALE','DETAIL_HEIGHT','mountains','rivers','materials'}) do
  assert(Terrain.defaults[name],'Missing semantic field')
end
local config={CONTINENT_SCALE=1024,SEA_LEVEL=52,OCEAN_FLOOR=12,DETAIL_HEIGHT=0}
local custom=World.new(1337,16,config)
for cy=-3,3 do for cx=-3,3 do
  local chunk=custom:generateChunk(cx,cy)
  for j=0,15 do for i=0,15 do
    assert(chunk.data[j*16+i]==custom:heightAt(cx*16+i,cy*16+j),'Configurable control interpolation mismatch')
  end end
end end
local function snapshot(w,x,y) return ffi.string(w:generateChunk(x,y).data,512) end
local expected=snapshot(world,-123,456)
for i=1,500 do world:generateChunk(i-250,i%43-20) end
assert(snapshot(world,-123,456)==expected,'Eviction/order changed terrain')
assert(snapshot(same,-123,456)==expected,'Cache size changed terrain')
assert(snapshot(world,62500,-62500)==snapshot(same,62500,-62500),'Far coordinates disagree')
local function checkQueue(w)
  local seen,count={},0;local index=w.first;local previous=0
  while index~=0 do
    assert(not seen[index],'Queue cycle/duplicate');seen[index]=true
    local c=w.chunks[index]
    assert(c.queued and c.previous==previous,'Queue links corrupted')
    assert(math.abs(c.requestX-w.cx)<=w.radius and math.abs(c.requestY-w.cy)<=w.radius,'Stale outside request')
    assert(w:slot(c.requestX,c.requestY)==index,'Wrong ring slot')
    previous=index;index=c.next;count=count+1
  end
  assert(previous==w.last and count==w.pendingCount and count<=w.slots^2)
end
local function drain(w) while w:hasPending() do w:step(256) end end
local function checkResident(w)
  for y=w.cy-w.radius,w.cy+w.radius do for x=w.cx-w.radius,w.cx+w.radius do
    local chunk=w.chunks[w:slot(x,y)]
    assert(chunk.x==x and chunk.y==y,'Visible chunk missing after drain')
    assert(w:height(x*16,y*16)==w:heightAt(x*16,y*16),'Resident data incorrect')
  end end
end
world:request(0,0);drain(world)
local generated=world.generated
world:request(16,0);assert(world.pendingCount==world.slots,'Normal X movement requested more than one strip')
drain(world);assert(world.generated-generated==world.slots)
world:request(32,16);assert(world.pendingCount==world.slots*2-1,'Diagonal movement requested wrong strips')
drain(world);checkResident(world)
-- Frequent reversals with unfinished work, all directions, negative coordinates.
for i=1,300 do
  local x=math.floor(8*math.sin(i*0.17));local y=math.floor(8*math.cos(i*0.23))
  world:request(x*16,y*16);world:step((i%3)*256);checkQueue(world)
end
world:request(-1000000,1000000);checkQueue(world);drain(world);checkResident(world)
world:request(0,0);drain(world);checkResident(world)
assert(snapshot(world,-123,456)==expected,'Movement/frame timing changed terrain')
-- No new chunk objects or buffers after warmup, even after thousands of replacements.
local objects,buffers={},{}
for i,c in ipairs(world.chunks) do objects[i]=c;buffers[i]=c.data end
for i=1,2000 do world:generateChunk(i,i%83) end
for i,c in ipairs(world.chunks) do assert(c==objects[i] and c.data==buffers[i],'Chunk pool allocated replacement storage') end
print('PASS: bulk/scalar fields, custom sparse grids, exact uint16 heights/maxima, seeds/order/eviction/far coordinates, strip requests, queue reversals/teleports, fixed buffer reuse')
