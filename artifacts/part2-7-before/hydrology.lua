-- Resolve complete downhill destinations, never truncate drainage at region edges.
-- Scratch memo belongs to one macro build; no chunk-loop allocations.
local G=require('geography')
local H={};H.__index=H
local function mix(a,b,t) return a+(b-a)*t end
function H.new(config,region,rx,ry,N,halo)
  return setmetatable({config=config,region=region,rx=rx,ry=ry,N=N,halo=halo,rows={},count=0},H)
end
function H:node(x,y)
  local row=self.rows[y];if not row then row={};self.rows[y]=row end
  if row[x] then return row[x] end
  local r,N=self.region,self.N
  local ix,iy=x-self.rx*32+self.halo,y-self.ry*32+self.halo
  local px=x*32+(G.hash(x,y,self.config.seed+1901)-0.5)*19
  local py=y*32+(G.hash(x,y,self.config.seed+2003)-0.5)*19
  local h
  if ix>=1 and iy>=1 and ix<N-1 and iy<N-1 then h=r.drainHeight[iy*N+ix]
  else
    local fx,fy=px/32,py/32;local gx,gy=math.floor(fx),math.floor(fy)
    local a=G.height(self.config,gx*32,gy*32)
    local b=G.height(self.config,(gx+1)*32,gy*32)
    local c=G.height(self.config,gx*32,(gy+1)*32)
    local d=G.height(self.config,(gx+1)*32,(gy+1)*32)
    h=mix(mix(a,b,fx-gx),mix(c,d,fx-gx),fy-gy)
  end
  local node={x=x,y=y,px=px,py=py,height=h};row[x]=node;self.count=self.count+1
  return node
end
function H:resolve(x,y)
  local start=self:node(x,y);local node=start
  while not node.base do
    if node.height<=self.config.SEA_LEVEL then
      node.base=self.config.SEA_LEVEL;node.ocean=true
    else
      local best,drop,spill=nil,0,math.huge
      for dy=-1,1 do for dx=-1,1 do if dx~=0 or dy~=0 then
        local other=self:node(node.x+dx,node.y+dy)
        spill=math.min(spill,other.height)
        local slope=(node.height-other.height)/math.sqrt((node.px-other.px)^2+(node.py-other.py)^2)
        if slope>drop then best,drop=other,slope end
      end end end
      if best then node.next=best;node=best
      else
        -- Lowest D8 rim is this sink's spill. All tributaries share this datum.
        node.base=math.max(self.config.SEA_LEVEL,math.floor(spill));node.ocean=false
        node.lakeWaterLevel=node.base
      end
    end
    coroutine.yield()
  end
  local base,ocean=node.base,node.ocean
  node=start
  while not node.base do
    node.base=base;node.ocean=ocean
    if not ocean then node.lakeWaterLevel=base end
    node=node.next
  end
  return start
end
function H.level(node)
  if node.ocean then return node.base end
  -- Long elevation bands form reaches; only explicit edge drops change level.
  return node.base+math.max(0,math.floor((node.height-1-node.base)/24))*24
end
return H
