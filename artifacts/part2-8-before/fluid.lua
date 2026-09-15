-- Sparse, immutable block geometry built with the macro region; never a frame simulation.
local Fluid={FULL=0,FLOW_1=1,FLOW_2=2,FLOW_3=3,FLOW_4=4,FLOW_5=5,FLOW_6=6,FLOW_7=7,FALLING=8}
local function mix(a,b,t) return a+(b-a)*t end
function Fluid.key(x,y) return (y+64)*1152+x+64 end
function Fluid.path(ax,ay,mx,my,bx,by,t)
  if t<=0.5 then return mix(ax,mx,t*2),mix(ay,my,t*2) end
  return mix(mx,bx,t*2-1),mix(my,by,t*2-1)
end
-- Sample uncarved support along the receiver/outlet, not categorical river water.
-- Equal reach metadata never vetoes a support-loss fall. Real water bodies can
-- support a stream; sample's second result is their actual surface, when present.
function Fluid.outlet(d,sample)
  d.reachLower=d.lower
  local length=math.sqrt((d.mx-d.ax)^2+(d.my-d.ay)^2)+math.sqrt((d.bx-d.mx)^2+(d.by-d.my)^2)
  local steps=math.max(1,math.ceil(length))
  local first,lowest,lip=nil,d.upper,nil
  local previous=sample(d.ax,d.ay)+1
  local steepest,bestDrop=0,0
  for i=1,steps do
    local t=i/steps;local x,y=Fluid.path(d.ax,d.ay,d.mx,d.my,d.bx,d.by,t)
    local terrain,water=sample(x,y)
    local support=math.max(math.floor(terrain)+1,water or 0)
    if support<d.upper and support<lowest then lowest=support end
    if support<d.upper and support<previous then
      first=first or t
      if previous>=d.upper then lip=t end
      if previous-support>bestDrop then bestDrop,steepest=previous-support,t end
    end
    previous=support
  end
  local lower=math.min(d.lower,lowest)
  if lower>=d.upper then return end
  d.lip=lip or first or steepest
  if d.lip==0 then d.lip=1/steps end
  d.lower,d.bottom,d.width=lower,lower-1,math.min(3,1+math.floor(math.sqrt(d.amount)/4))
  d.kind=d.upper-lower<=1 and 'ramp' or 'fall'
  local dx,dy=d.lip<=0.5 and d.mx-d.ax or d.bx-d.mx,d.lip<=0.5 and d.my-d.ay or d.by-d.my
  local span=math.max(1e-9,math.sqrt(dx*dx+dy*dy));d.dx,d.dy=dx/span,dy/span
  return d
end
local function project(x,y,ax,ay,bx,by)
  local dx,dy=bx-ax,by-ay
  local t=math.max(0,math.min(1,((x-ax)*dx+(y-ay)*dy)/(dx*dx+dy*dy)))
  return (x-ax-dx*t)^2+(y-ay-dy*t)^2,t
end
function Fluid.build(region,config,rx,ry,F,M)
  local cells,lakes=region.fluid,region.lakes or {}
  local function lakeLevel(x,y)
    local level,best=0,2
    for _,lake in ipairs(lakes) do
      local wet=lake.width-math.sqrt((x-lake.x)^2+(y-lake.y)^2)
      if wet>best then level,best=lake.level,wet end
    end
    return level
  end
  local function inside(x,y) return x>=-M+2 and y>=-M+2 and x<1024+M-2 and y<1024+M-2 end
  local function sample(x,y)
    local fx,fy=(x+M)/4,(y+M)/4;local ix,iy=math.floor(fx),math.floor(fy)
    local u,v=fx-ix,fy-iy;local k=iy*F+ix;local b=region.bed
    local h=math.floor(mix(mix(b[k],b[k+F],v),mix(b[k+1],b[k+F+1],v),u))
    local wet=region.wet;local w=mix(mix(wet[k],wet[k+F],v),mix(wet[k+1],wet[k+F+1],v),u)
    local top=w>0 and region.water[(iy+(v>=0.5 and 1 or 0))*F+ix+(u>=0.5 and 1 or 0)] or 0
    return h,top
  end
  local function put(x,y,top,bed,state)
    local body=lakeLevel(x,y)
    if body>0 and top>body and state~=Fluid.FALLING then top,state=body,Fluid.FULL end
    local key=Fluid.key(x,y);local c=cells[key]
    if not c then c={};cells[key]=c end
    if not c.top or top>c.top or top==c.top and state==Fluid.FALLING then c.top,c.state=top,state end
    c.bed=math.min(c.bed or 254,bed);c.bank=nil
  end
  for _,d in ipairs(region.drops) do
    local width=3+math.sqrt(d.amount)*1.3
    local length=math.sqrt((d.mx-d.ax)^2+(d.my-d.ay)^2)+math.sqrt((d.bx-d.mx)^2+(d.by-d.my)^2)
    local lx,ly=Fluid.path(d.ax,d.ay,d.mx,d.my,d.bx,d.by,d.lip)
    d.x,d.y=math.floor(lx),math.floor(ly)
    local radius=width*2+10
    for y=math.max(-M+2,math.floor(math.min(d.ay,d.my,ly)-radius)),math.min(1024+M-3,math.ceil(math.max(d.ay,d.my,ly)+radius)) do
      for x=math.max(-M+2,math.floor(math.min(d.ax,d.mx,lx)-radius)),math.min(1024+M-3,math.ceil(math.max(d.ax,d.mx,lx)+radius)) do
        local a,ta=project(x,y,d.ax,d.ay,d.mx,d.my)
        local b,tb=project(x,y,d.mx,d.my,d.bx,d.by)
        local t=a<=b and ta*0.5 or 0.5+tb*0.5
        local distance=math.sqrt(math.min(a,b))
        local remaining=(d.lip-t)*length
        local upstream=(x-d.ax)*(d.mx-d.ax)+(y-d.ay)*(d.my-d.ay)<0
        -- A capped segment's projection also covers points behind its start.
        -- Preserve the feeder there instead of extending the lip's dry banks.
        if remaining>=0 and (not upstream or distance<=width) then
          local channel=upstream and width or 1.25+(width-1.25)*math.min(1,remaining/12)
          if distance<=channel then
            put(x,y,d.upper,d.upper-2,Fluid.FULL)
          elseif distance<radius then
            local key=Fluid.key(x,y);local c=cells[key]
            local _,water=sample(x,y)
            if lakeLevel(x,y)==0 and not (d.lake and remaining>6 and water>=d.upper) then
              if not c then c={};cells[key]=c end
              if not c.top then c.bank=math.max(c.bank or 0,d.upper) end
            end
          end
        end
      end
      coroutine.yield()
    end
    if d.kind=='ramp' then
      -- Eight supported horizontal cells replace a one-block vertical transition.
      local px,py=math.floor(lx),math.floor(ly)
      for step=0,8 do
        local x,y=math.floor(lx+d.dx*step),math.floor(ly+d.dy*step)
        if inside(x,y) then put(x,y,d.upper-step/8,d.lower-1,step==8 and Fluid.FULL or step) end
        if x~=px and y~=py and inside(px,y) then put(px,y,d.upper-step/8,d.lower-1,step==8 and Fluid.FULL or step) end
        px,py=x,y
      end
    end
    -- One center voxel joins upper reach to supported landing; column contains all z.
    if d.kind~='ramp' and inside(d.x,d.y) then
      put(d.x,d.y,d.upper,d.bottom or d.lower-2,Fluid.FALLING)
      -- Downward escape wins. Landing resets FLOW_1..7, while a separate
      -- fourteen-step travel budget bounds secondary falls and total work.
      local ground,water=sample(d.x,d.y)
      local queue={{x=d.x,y=d.y,level=math.max(ground,water)+1,flow=0,travel=0}};local head=1;local seen={}
      while head<=#queue do
        local q=queue[head];head=head+1
        if q.flow<7 and q.travel<14 then
          local candidates={}
          for _,offset in ipairs({{0,-1},{-1,0},{1,0},{0,1}}) do
            local x,y=q.x+offset[1],q.y+offset[2]
            if inside(x,y) then
              local bed,water=sample(x,y);local existing=cells[Fluid.key(x,y)]
              if existing then bed=math.max(existing.bank or 0,math.min(bed,existing.bed or 254)) end
              local support=math.max(bed,water,existing and existing.top or 0)
              local escape=support<math.floor(q.level)-1 and 0 or 3
              -- Look two blocks ahead for a downward outlet; deterministic D4 order.
              if escape>0 then
                for _,route in ipairs({{0,-1},{-1,0},{1,0},{0,1}}) do
                  local xx,yy=x+route[1],y+route[2]
                  if inside(xx,yy) then
                    local ground,waterBelow=sample(xx,yy)
                    local block=cells[Fluid.key(xx,yy)]
                    if block then ground=math.max(block.bank or 0,math.min(ground,block.bed or 254)) end
                    if math.max(ground,waterBelow,block and block.top or 0)<math.floor(q.level)-1 then escape=1 end
                  end
                end
              end
              candidates[#candidates+1]={x=x,y=y,bed=bed,support=support,escape=escape}
            end
          end
          table.sort(candidates,function(a,b)
            if a.escape~=b.escape then return a.escape<b.escape end
            if a.support~=b.support then return a.support<b.support end
            if a.y~=b.y then return a.y<b.y end
            return a.x<b.x
          end)
          for _,c in ipairs(candidates) do
            local top=q.level-(q.flow+1)/8
            if c.support<top and (candidates[1].escape==3 or c.escape==candidates[1].escape) then
              local key=Fluid.key(c.x,c.y)
              if not seen[key] or seen[key]<top then
                seen[key]=top
                local falling=c.support<math.floor(top)-1
                put(c.x,c.y,falling and math.ceil(top) or top,c.bed,falling and Fluid.FALLING or q.flow+1)
                queue[#queue+1]={x=c.x,y=c.y,level=falling and c.support+1 or q.level,flow=falling and 0 or q.flow+1,travel=q.travel+1}
              end
            end
          end
        end
      end
    end
  end
  -- Different resolved basins can touch in the coarse raster. Keep a bank on
  -- the higher inland side instead of exposing an arbitrary lake-wide water wall.
  -- Inspect only controls with a level discontinuity, never all world columns.
  for gy=1,F-3 do for gx=1,F-3 do
    local k=gy*F+gx;local w=region.water
    local lo=math.min(w[k],w[k+1],w[k+F],w[k+F+1])
    local hi=math.max(w[k],w[k+1],w[k+F],w[k+F+1])
    if hi>config.SEA_LEVEL and hi-lo>1 then
      for y=gy*4-M-1,gy*4-M+4 do for x=gx*4-M-1,gx*4-M+4 do
        if inside(x,y) then
          local key=Fluid.key(x,y);local c=cells[key]
          local _,top=sample(x,y)
          if top>config.SEA_LEVEL and not (c and c.top) then
            local boundary=false
            for dy=-1,1 do for dx=-1,1 do
              local _,other=sample(x+dx,y+dy)
              local neighbor=cells[Fluid.key(x+dx,y+dy)]
              if other>0 and other<top-1 and not (neighbor and neighbor.top) then boundary=true end
            end end
            if boundary then
              cells[key]=c or {};cells[key].bank=math.max(cells[key].bank or 0,top)
            end
          end
        end
      end end
    end
  end;coroutine.yield() end
  -- Explicit banks also guard adjacent dry voxels at lips/landings. Wet neighbors
  -- retain their own surface; only the narrow falling column exposes a tall face.
  local banks={}
  for key,c in pairs(cells) do
    local y=math.floor(key/1152)-64;local x=key%1152-64
    local _,water=sample(x,y)
    local top=c.top or (water>(c.bank or 0) and water or nil)
    if top then
    for dy=-1,1 do for dx=-1,1 do
      local xx,yy=x+dx,y+dy;local nk=Fluid.key(xx,yy)
      if inside(xx,yy) and not (cells[nk] and cells[nk].top) then
        local _,water=sample(xx,yy)
        if water==0 or cells[nk] and cells[nk].bank then banks[nk]=math.max(banks[nk] or 0,math.ceil(top)) end
      end
    end end
  end end
  for key,h in pairs(banks) do
    cells[key]=cells[key] or {};cells[key].bank=math.max(cells[key].bank or 0,h)
  end
  -- Immutable sparse block primitives indexed once by overlapping chunk.
  region.fluidChunks={}
  for key,c in pairs(cells) do
    local y=math.floor(key/1152)-64;local x=key%1152-64
    if x>=0 and x<1024 and y>=0 and y<1024 then
      local chunk=math.floor(y/16)*64+math.floor(x/16)
      local records=region.fluidChunks[chunk]
      if not records then records={};region.fluidChunks[chunk]=records end
      records[(y%16)*16+x%16]=c
    end
  end
end
return Fluid
