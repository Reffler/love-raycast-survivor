-- Sparse, immutable block geometry built with the macro region; never a frame simulation.
local Fluid={FULL=0,FLOW_1=1,FLOW_2=2,FLOW_3=3,FLOW_4=4,FLOW_5=5,FLOW_6=6,FLOW_7=7,FALLING=8}
local function mix(a,b,t) return a+(b-a)*t end
function Fluid.key(x,y) return (y+64)*1152+x+64 end
function Fluid.path(ax,ay,mx,my,bx,by,t)
  if t<=0.5 then return mix(ax,mx,t*2),mix(ay,my,t*2) end
  return mix(mx,bx,t*2-1),mix(my,by,t*2-1)
end
local function project(x,y,ax,ay,bx,by)
  local dx,dy=bx-ax,by-ay
  local t=math.max(0,math.min(1,((x-ax)*dx+(y-ay)*dy)/(dx*dx+dy*dy)))
  return (x-ax-dx*t)^2+(y-ay-dy*t)^2,t
end
function Fluid.build(region,config,rx,ry,F,M)
  local cells=region.fluid
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
        if remaining>=0 then
          local channel=1.25+(width-1.25)*math.min(1,remaining/12)
          if distance<=channel then
            put(x,y,d.upper,d.upper-2,Fluid.FULL)
          elseif distance<radius then
            local key=Fluid.key(x,y);local c=cells[key]
            if not c then c={};cells[key]=c end
            if not c.top then c.bank=math.max(c.bank or 0,d.upper) end
          end
        end
      end
      coroutine.yield()
    end
    -- One center voxel joins upper reach to supported landing; column contains all z.
    if inside(d.x,d.y) then
      put(d.x,d.y,d.upper,d.lower-2,Fluid.FALLING)
      -- Deterministic bounded priority flood. Downward escape wins; horizontal
      -- distance remains capped at seven even after a fall (finite static work).
      local ground,water=sample(d.x,d.y)
      local queue={{x=d.x,y=d.y,level=math.max(ground,water)+1,flow=0}};local head=1;local seen={}
      while head<=#queue do
        local q=queue[head];head=head+1
        if q.flow<7 then
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
                queue[#queue+1]={x=c.x,y=c.y,level=falling and c.support+1 or q.level,flow=q.flow+1}
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
  for key,c in pairs(cells) do if c.top then
    local y=math.floor(key/1152)-64;local x=key%1152-64
    for dy=-1,1 do for dx=-1,1 do
      local xx,yy=x+dx,y+dy;local nk=Fluid.key(xx,yy)
      if inside(xx,yy) and not (cells[nk] and cells[nk].top) then
        local _,water=sample(xx,yy)
        if water==0 or cells[nk] and cells[nk].bank then banks[nk]=math.max(banks[nk] or 0,math.ceil(c.top)) end
      end
    end end
  end end
  for key,h in pairs(banks) do
    cells[key]=cells[key] or {};cells[key].bank=math.max(cells[key].bank or 0,h)
  end
end
return Fluid
