-- Deterministic slow-prefetch fixture: visible terrain must never use recycled slots.
local World=require('world')
local clock=0
love={timer={getTime=function() clock=clock+0.001;return clock end}}
local world=World.new(1337,556)
-- Isolate streaming from terrain cost; force background generation to stall.
world.terrain={spanOverflowCount=0,ready=function() return false end,advance=function() end,
  generate=function() return 100,false end}
local uploaded={}
world.upload=function(c) uploaded[c.index]={x=c.x,y=c.y} end
local function drain(x,y)
  world:request(x,y);world:step(world.slots^2*256,world.upload)
end
local function check(x,y)
  world:update(x,y)
  local radius=558
  for cy=math.floor((y-radius)/16),math.floor((y+radius)/16) do
    for cx=math.floor((x-radius)/16),math.floor((x+radius)/16) do
      local dx=math.max(cx*16-x,0,x-(cx+1)*16)
      local dy=math.max(cy*16-y,0,y-(cy+1)*16)
      if dx*dx+dy*dy<=radius^2 then
        local c=world.chunks[world:slot(cx,cy)];local gpu=uploaded[c.index]
        assert(c.x==cx and c.y==cy,('Visible slot stale at %.2f,%.2f: %d,%d'):format(x,y,cx,cy))
        assert(gpu and gpu.x==cx and gpu.y==cy,'Visible GPU upload stale')
      end
    end
  end
  local seen,count,previous={},0,0;local index=world.first
  while index~=0 do
    local c=world.chunks[index]
    assert(not seen[index] and c.queued and c.previous==previous,'Queue corrupted')
    seen[index]=true;count=count+1;previous=index;index=c.next
  end
  assert(count==world.pendingCount and previous==world.last,'Queue count/tail corrupted')
end
drain(3.5,3.5)
for _,path in ipairs({{25,60,1,0},{50,60,1,0},{50,30,-1,0},{50,15,0.7071,-0.7071}}) do
  local speed,fps,dx,dy=unpack(path)
  for frame=1,fps*12 do check(3.5+frame*speed/fps*dx,3.5+frame*speed/fps*dy) end
end
for _,p in ipairs({{-1000000.5,1000000.5},{1023.9,-1024.1},{1024.1,-1023.9},{0,0}}) do check(unpack(p)) end
print('PASS: visible CPU/GPU residency plus neighbor halo at walk/sprint speeds, 15/30/60 FPS, reversals, negative seams, teleports; stalled prefetch and queue integrity')
