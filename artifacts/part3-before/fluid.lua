-- Sparse, immutable block geometry built with the macro region; never a frame simulation.
local C=require('river_geometry')
local Fluid={FULL=0,FLOW_1=1,FLOW_2=2,FLOW_3=3,FLOW_4=4,FLOW_5=5,FLOW_6=6,FLOW_7=7,FALLING=8}
local function mix(a,b,t) return a+(b-a)*t end
-- Region-local coordinates differ by integer translations. Stabilize points
-- landing on a voxel boundary after normal/tangent arithmetic.
local function block(x) return math.floor(x+1e-7) end
function Fluid.key(x,y) return (y+64)*1152+x+64 end
-- Sample uncarved support along the receiver/outlet, not categorical river water.
-- Equal reach metadata never vetoes a support-loss fall. Real water bodies can
-- support a stream; sample's second result is their actual surface, when present.
function Fluid.outlet(d,sample)
  C.curve(d)
  d.reachLower=d.lower
  local length=d.length
  local steps=math.max(1,math.ceil(length))
  local first,lowest,lip=nil,d.upper,nil
  local previous=sample(d.ax,d.ay)+1
  local steepest,bestDrop=0,0
  for i=1,steps do
    local t=i/steps;local x,y=C.at(d,t)
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
  d.lower,d.bottom,d.width=lower,lower-1,math.max(2,math.min(8,math.floor(C.width(d.amount)*0.55+0.5)))
  d.kind=d.upper-lower<=1 and 'ramp' or 'fall'
  local lx,ly,dx,dy=C.at(d,d.lip);d.dx,d.dy=dx,dy
  d.faces={}
  if d.kind=='fall' then
    local seen={}
    for lane=0,d.width-1 do
      local offset=lane-(d.width-1)/2
      local candidate
      -- Each lane finds the first air cell with a supported cardinal neighbor
      -- behind it. This follows uneven lips instead of excavating a straight slot.
      for step=-6,8 do
        local x,y=block(lx-dy*offset+dx*step),block(ly+dx*offset+dy*step)
        local ground=math.floor(sample(x,y))
        local bx,by,bh=x,y,-math.huge
        if math.abs(dx)>1e-6 then
          local xx=x-(dx>0 and 1 or -1);local h=math.floor(sample(xx,y))
          if h>bh then bx,by,bh=xx,y,h end
        end
        if math.abs(dy)>1e-6 then
          local yy=y-(dy>0 and 1 or -1);local h=math.floor(sample(x,yy))
          if h>bh then bx,by,bh=x,yy,h end
        end
        if ground<d.upper-1 and bh>=d.upper-1 then
          candidate={x=x,y=y,bx=bx,by=by,ground=ground,backing=math.min(bh,d.upper-1)}
          break
        end
      end
      if not candidate then
        -- A categorical reach drop has already cut its lower channel. Preserve
        -- that channel and put the face immediately in front of the upper lip.
        local x,y=block(lx-dy*offset+dx),block(ly+dx*offset+dy)
        local bx,by=x,y
        if math.abs(dx)>=math.abs(dy) then bx=x-(dx>0 and 1 or -1) else by=y-(dy>0 and 1 or -1) end
        candidate={x=x,y=y,bx=bx,by=by,backing=d.upper-1}
      end
      local key=Fluid.key(candidate.x,candidate.y)
      if not seen[key] then d.faces[#d.faces+1]=candidate;seen[key]=true end
    end
  end
  return d
end
function Fluid.build(region,config,rx,ry,F,M)
  local cells,lakes=region.fluid,region.lakes or {}
  local function lakeLevel(x,y)
    local level,best=0,2
    for _,lake in ipairs(lakes) do
      local wet=lake.width-C.lakeDistance(lake,x,y)
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
    local level=region.water[(iy+(v>=0.5 and 1 or 0))*F+ix+(u>=0.5 and 1 or 0)]
    return h,w>0 and level or 0,w,level
  end
  local function put(x,y,top,bed,state)
    local body=lakeLevel(x,y)
    if body>0 and top>body and state~=Fluid.FALLING then top,state=body,Fluid.FULL end
    local key=Fluid.key(x,y);local c=cells[key]
    if not c then c={};cells[key]=c end
    if not c.top or top>c.top or top==c.top and state==Fluid.FALLING then c.top,c.state=top,state end
    if c.state==Fluid.FALLING then c.bed=nil
    elseif bed then c.bed=math.min(c.bed or 254,bed) end
    c.bank=nil
  end
  for _,d in ipairs(region.drops) do
    C.curve(d)
    local width=C.width(d.amount)
    local length=d.length
    local lx,ly,dx,dy=C.at(d,d.lip)
    local _,_,tx,ty=C.at(d,0)
    d.dx,d.dy=d.dx or dx,d.dy or dy
    d.width=d.width or math.max(2,math.min(8,math.floor(width*0.55+0.5)))
    d.x,d.y=block(lx),block(ly)
    local radius=width*2+10
    for y=math.max(-M+2,math.floor(d.miny-radius)),math.min(1024+M-3,math.ceil(d.maxy+radius)) do
      for x=math.max(-M+2,math.floor(d.minx-radius)),math.min(1024+M-3,math.ceil(d.maxx+radius)) do
        local distance,t=C.distance(d,x,y)
        local remaining=(d.lip-t)*length
        local upstream=(x-d.ax)*tx+(y-d.ay)*ty<0
        -- A capped segment's projection also covers points behind its start.
        -- Preserve the feeder there instead of extending the lip's dry banks.
        if remaining>=0 and (not upstream or distance<=width) then
          local channel=upstream and width or d.width/2+(width-d.width/2)*math.min(1,remaining/(width*2))
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
      local px,py=block(lx),block(ly)
      for step=0,8 do
        local x,y=block(lx+d.dx*step),block(ly+d.dy*step)
        if inside(x,y) then put(x,y,d.upper-step/8,d.lower-1,step==8 and Fluid.FULL or step) end
        if x~=px and y~=py and inside(px,y) then put(px,y,d.upper-step/8,d.lower-1,step==8 and Fluid.FULL or step) end
        px,py=x,y
      end
    end
    if d.kind~='ramp' then
      d.faces=d.faces or {}
      if #d.faces==0 then
        for lane=0,d.width-1 do
          local offset=lane-(d.width-1)/2
          local x,y=block(lx-d.dy*offset),block(ly+d.dx*offset)
          local bx,by=x,y
          if math.abs(d.dx)>=math.abs(d.dy) then bx=x-(d.dx>0 and 1 or -1) else by=y-(d.dy>0 and 1 or -1) end
          d.faces[#d.faces+1]={x=x,y=y,bx=bx,by=by,backing=d.upper-1}
        end
      end
      local queue,head,seen={},1,{}
      for _,face in ipairs(d.faces) do
        if not face.ground then
          -- Coarse reach terraces interpolate across four blocks. Locate their
          -- first lower supported cell before placing the sheet, never dig it.
          local sx,sy=face.x,face.y
          for step=0,10 do
            local x,y=block(sx+d.dx*step),block(sy+d.dy*step)
            if inside(x,y) then
              local ground,water=sample(x,y)
              if ground<d.lower and water<=d.lower then
                face.x,face.y=x,y;face.bx,face.by=x,y
                if math.abs(d.dx)>=math.abs(d.dy) then face.bx=x-(d.dx>0 and 1 or -1)
                else face.by=y-(d.dy>0 and 1 or -1) end
                break
              end
            end
          end
        end
        if inside(face.x,face.y) and inside(face.bx,face.by) then
        local sx,sy=C.at(d,math.max(0,d.lip-8/length))
        local px,py=block(sx),block(sy)
        local steps=math.max(math.abs(face.bx-px),math.abs(face.by-py),1)
        sx,sy=px,py
        for step=0,steps do
          local x,y=block(mix(sx,face.bx,step/steps)),block(mix(sy,face.by,step/steps))
          if inside(x,y) then put(x,y,d.upper,d.upper-1,Fluid.FULL) end
          if x~=px and y~=py and inside(px,y) then put(px,y,d.upper,d.upper-1,Fluid.FULL) end
          px,py=x,y
        end
        -- Lip exception: a shallow full-water connector above an intact cliff.
        put(face.bx,face.by,d.upper,nil,Fluid.FULL)
        local back=cells[Fluid.key(face.bx,face.by)]
        back.floor=math.max(back.floor or 0,face.backing)
        local ground,water=sample(face.x,face.y)
        put(face.x,face.y,d.upper,nil,Fluid.FALLING)
        local fall=cells[Fluid.key(face.x,face.y)]
        fall.floor=math.max(fall.floor or 0,face.ground or ground)
        face.bottom=fall.floor
        queue[#queue+1]={x=face.x,y=face.y,level=math.max(fall.floor,water)+1,flow=0,travel=0}
      end end
      -- Existing bounded landing spread, seeded across the entire sheet.
      while head<=#queue do
        local q=queue[head];head=head+1
        if q.flow<7 and q.travel<14 then
          local candidates={}
          for _,offset in ipairs({{0,-1},{-1,0},{1,0},{0,1}}) do
            local x,y=q.x+offset[1],q.y+offset[2]
            if inside(x,y) then
              local bed,water=sample(x,y);local existing=cells[Fluid.key(x,y)]
              if existing then bed=math.max(existing.bank or 0,existing.floor or 0,math.min(bed,existing.bed or 254)) end
              local support=math.max(bed,water,existing and existing.top or 0)
              local escape=support<math.floor(q.level)-1 and 0 or 3
              -- Look two blocks ahead for a downward outlet; deterministic D4 order.
              if escape>0 then
                for _,route in ipairs({{0,-1},{-1,0},{1,0},{0,1}}) do
                  local xx,yy=x+route[1],y+route[2]
                  if inside(xx,yy) then
                    local ground,waterBelow=sample(xx,yy)
                    local block=cells[Fluid.key(xx,yy)]
                    if block then ground=math.max(block.bank or 0,block.floor or 0,math.min(ground,block.bed or 254)) end
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
  local banks,candidates={},{}
  local function occupied(x,y)
    local h,water,wet,level=sample(x,y);local c=cells[Fluid.key(x,y)]
    if water>0 then h=math.min(h,water-1) end
    if level>config.SEA_LEVEL and wet<=0 and wet>-4 then h=math.max(h,level+1) end
    if c then h=math.max(c.bank or 0,c.floor or 0,math.min(h,c.bed or 254)) end
    local top=c and c.top or water
    return top>h and top or 0
  end
  for key in pairs(cells) do
    local y=math.floor(key/1152)-64;local x=key%1152-64
    for dy=-1,1 do for dx=-1,1 do
      if inside(x+dx,y+dy) then candidates[Fluid.key(x+dx,y+dy)]=true end
    end end
  end
  for key in pairs(candidates) do
    local y=math.floor(key/1152)-64;local x=key%1152-64
    local top=occupied(x,y)
    if top>0 then
      for dy=-1,1 do for dx=-1,1 do
        local xx,yy=x+dx,y+dy;local nk=Fluid.key(xx,yy)
        if inside(xx,yy) and occupied(xx,yy)==0 then banks[nk]=math.max(banks[nk] or 0,math.ceil(top)) end
      end end
    end
  end
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
