-- Sparse global cave graph, analytic XY rasterization; never samples a Z volume.
local ffi,G=require('ffi'),require('geography')
local C={MAX_SPANS=4,SPACING=192,WATER_ROOF=6}
local function capsule(ax,ay,az,bx,by,bz,r,kind)
  local vx,vy,vz=bx-ax,by-ay,bz-az
  return {ax=ax,ay=ay,az=az,bx=bx,by=by,bz=bz,vx=vx,vy=vy,vz=vz,xyLength=vx*vx+vy*vy,length=vx*vx+vy*vy+vz*vz,r=r,kind=kind or 'tunnel',
    minx=math.min(ax,bx)-r*1.1,maxx=math.max(ax,bx)+r*1.1,
    miny=math.min(ay,by)-r*1.1,maxy=math.max(ay,by)+r*1.1}
end
C.capsule=capsule
function C.build(region,config,rx,ry,height)
  local start=os.clock();local cpu=0;local ox,oy=rx*1024,ry*1024
  local nodes,primitives,bins={},{},{}
  region.caveNodes,region.cavePrimitives,region.caveBins=nodes,primitives,bins
  region.caveEntrances={};region.caveFeatures={}
  if not config.caves then region.caveBuildSeconds=0;return end
  local function pause() cpu=cpu+os.clock()-start;coroutine.yield();start=os.clock() end
  local function random(x,y,salt) return G.hash(x,y,config.seed+salt) end
  local function node(gx,gy)
    local key=gx..','..gy;local n=nodes[key];if n then return n end
    local x=(gx+0.5)*192+(random(gx,gy,3109)-0.5)*80
    local y=(gy+0.5)*192+(random(gx,gy,3163)-0.5)*80
    local h=height(x,y)
    n={x=x,y=y,z=math.max(10,math.min(h-14,16+0.26*(h-config.SEA_LEVEL)+12*random(gx,gy,3203))),
      radius=random(gx,gy,3251)>0.86 and 13+8*random(gx,gy,3253) or 4+3*random(gx,gy,3253),
      type='junction',height=h,active=h>config.SEA_LEVEL+10}
    n.type=n.radius>10 and 'chamber' or 'junction'
    nodes[key]=n;return n
  end
  local function add(p)
    if p.maxx<ox or p.minx>=ox+1024 or p.maxy<oy or p.miny>=oy+1024 then return end
    primitives[#primitives+1]=p
    for cy=math.max(0,math.floor((p.miny-oy)/16)),math.min(63,math.floor((p.maxy-oy)/16)) do
      for cx=math.max(0,math.floor((p.minx-ox)/16)),math.min(63,math.floor((p.maxx-ox)/16)) do
        -- Conservative projected capsule/chunk test avoids bins covering empty diagonal corners.
        local dx,dy=ox+cx*16+8-p.ax,oy+cy*16+8-p.ay
        local t=p.xyLength>0 and math.max(0,math.min(1,(dx*p.vx+dy*p.vy)/p.xyLength)) or 0
        if (dx-t*p.vx)^2+(dy-t*p.vy)^2<=(p.r*1.1+12)^2 then
          local key=cy*64+cx;local bin=bins[key]
          if not bin then bin={};bins[key]=bin end
          bin[#bin+1]=p;assert(#bin<=512,'Cave primitive bin exceeds scratch capacity')
        end
      end
    end
    pause()
  end
  local function connect(a,b,r,kind)
    add(capsule(a.x,a.y,a.z,b.x,b.y,b.z,r,kind))
  end
  for gy=math.floor((oy-384)/192),math.floor((oy+1408)/192) do
    for gx=math.floor((ox-384)/192),math.floor((ox+1408)/192) do
      local a=node(gx,gy)
      if a.active then
        local room=capsule(a.x,a.y,a.z,a.x,a.y,a.z,a.radius,'chamber')
        room.rz=a.radius*0.65;add(room)
        -- Two canonical edges yield long connected systems and loops; diagonal links branch.
        for direction=1,3 do
          local b=node(gx+(direction~=2 and 1 or 0),gy+(direction~=1 and 1 or 0))
          if b.active and (direction<3 or random(gx,gy,3313)>0.65) then
            local bend={x=(a.x+b.x)/2+24*(random(gx,gy,3323+direction)-0.5),
              y=(a.y+b.y)/2+24*(random(gx,gy,3331+direction)-0.5),z=(a.z+b.z)/2+4*(random(gx,gy,3343+direction)-0.5)}
            local radius=3.5+2.5*random(gx,gy,3359+direction)
            connect(a,bend,radius);connect(bend,b,radius)
          end
        end
        -- Search local terrain for a deliberate slope/cliff mouth, then connect it to graph.
        if random(gx,gy,3407)>0.38 then
          local best,score=nil,0.30
          for j=0,7 do
            local angle=j*math.pi/4;local dx,dy=math.cos(angle),math.sin(angle)
            local x,y=a.x+dx*64,a.y+dy*64
            local h=height(x,y);local behind=height(x-dx*18,y-dy*18);local outside=height(x+dx*18,y+dy*18)
            local slope=(behind-outside)/36
            if h>config.SEA_LEVEL+15 and slope>score then best={x=x,y=y,z=h-5,dx=dx,dy=dy,height=h};score=slope end
          end
          if best then
            local r=3+5*random(gx,gy,3433)
            local mouth={x=best.x+best.dx*22,y=best.y+best.dy*22,z=best.z-3}
            connect(a,best,r,'entrance');connect(best,mouth,r,'entrance')
            if best.x>=ox and best.x<ox+1024 and best.y>=oy and best.y<oy+1024 then
              best.radius=r;best.type='cliff';region.caveEntrances[#region.caveEntrances+1]=best
            end
            if score>0.7 and random(gx,gy,3457)>0.90 then
              -- Rare surface-opening fissure; vertical ellipsoids form a narrow ravine.
              for j=-3,3 do
                local x,y=best.x-best.dy*j*6,best.y+best.dx*j*6
                local p=capsule(x,y,height(x,y)-7,x,y,height(x,y)-7,4.5,'ravine');p.rz=19;add(p)
              end
            end
          elseif a.height>config.SEA_LEVEL+24 and random(gx,gy,3461)>0.88 then
            local mouth={x=a.x+18,y=a.y-12,z=height(a.x+18,a.y-12)+3}
            connect(a,mouth,3,'shaft')
            if a.x>=ox and a.x<ox+1024 and a.y>=oy and a.y<oy+1024 then region.caveEntrances[#region.caveEntrances+1]=mouth;mouth.type='shaft';mouth.radius=3 end
          end
        end
        -- A real bridge requires two exposed mouths and a thick center roof.
        if a.height>config.SEA_LEVEL+30 then
          local found=false
          for j=0,7 do
            local angle=j*math.pi/4;local dx,dy=math.cos(angle),math.sin(angle)
            local x,y=a.x+dx*40,a.y+dy*40;local h=height(x,y)
            local tx,ty=-dy,dx;local left,right=height(x-tx*42,y-ty*42),height(x+tx*42,y+ty*42)
            local r=5;local z=math.max(left,right)+r+2
            if not found and math.min(left,right)>config.SEA_LEVEL+8 and h>z+r+5 then
              add(capsule(x-tx*48,y-ty*48,z,x+tx*48,y+ty*48,z,r,'arch'));found=true
              if x>=ox and x<ox+1024 and y>=oy and y<oy+1024 then
                region.caveFeatures[#region.caveFeatures+1]={x=x,y=y,z=z,dx=tx,dy=ty,type='arch'}
              end
            end
          end
        end
      end
    end
    pause()
  end
  region.caveBuildSeconds=cpu+os.clock()-start
end
-- Exact vertical line intersection with a capsule; endpoints plus finite cylinder.
function C.interval(p,x,y,rough)
  local r=p.r*(0.94+0.12*rough)
  local ax,ay=x-p.ax,y-p.ay
  if p.rz then
    local q=1-(ax*ax+ay*ay)/(r*r)
    if q<=0 then return end
    local dz=p.rz*math.sqrt(q);return p.az-dz,p.az+dz
  end
  local lo,hi=math.huge,-math.huge
  local q=r*r-ax*ax-ay*ay
  if q>0 then local dz=math.sqrt(q);lo,hi=p.az-dz,p.az+dz end
  local bx,by=x-p.bx,y-p.by;q=r*r-bx*bx-by*by
  if q>0 then local dz=math.sqrt(q);lo,hi=math.min(lo,p.bz-dz),math.max(hi,p.bz+dz) end
  local vx,vy,vz=p.vx,p.vy,p.vz
  local length=p.length
  if length>0 then
    local dot=ax*vx+ay*vy;local a=(vx*vx+vy*vy)/length
    if a>1e-10 then
      local b=-2*dot*vz/length;local c=ax*ax+ay*ay-dot*dot/length-r*r
      local disc=b*b-4*a*c
      if disc>=0 then
        local root=math.sqrt(disc);local l,h=(-b-root)/(2*a),(-b+root)/(2*a)
        if math.abs(vz)>1e-10 then
          local s,t=-dot/vz,(length-dot)/vz;l=math.max(l,math.min(s,t));h=math.min(h,math.max(s,t))
        elseif dot<0 or dot>length then l,h=1,0 end
        if h>=l then lo,hi=math.min(lo,p.az+l),math.max(hi,p.az+h) end
      end
    elseif ax*ax+ay*ay<r*r then
      lo,hi=math.min(lo,p.az,p.bz),math.max(hi,p.az,p.bz)
    end
  end
  if hi>lo then return lo,hi end
end
-- Protect wet beds AND their banks; tall bank height alone does not seal a lake side.
function C.protectedHeight(h,water,wetness,level,sea)
  if water>0 then return h end
  if wetness>-8 and level>0 then return math.min(h,level-8) end
  if h<sea+24 then return math.min(h,sea-8) end
end
function C.newScratch() return ffi.new('double[1024]') end
-- Sorted merged air intervals, then complement. Scratch and output are reused.
function C.column(bin,x,y,h,protected,rough,out,offset,scratch)
  local n=0
  local limit=protected and math.min(h,type(protected)=='number' and protected or h)-C.WATER_ROOF or h
  if bin and h>8 then
    for j=1,#bin do
      local p=bin[j]
      if x>=p.minx and x<=p.maxx and y>=p.miny and y<=p.maxy then
        local lo,hi=C.interval(p,x,y,rough)
        if lo then
          lo=math.max(3,math.floor(lo));hi=math.min(limit,math.ceil(hi))
          if hi-lo>=2 then
            local k=n
            while k>0 and scratch[(k-1)*2]>lo do scratch[k*2]=scratch[(k-1)*2];scratch[k*2+1]=scratch[(k-1)*2+1];k=k-1 end
            scratch[k*2],scratch[k*2+1]=lo,hi;n=n+1
          end
        end
      end
    end
  end
  local merged=0
  for j=0,n-1 do
    local lo,hi=scratch[j*2],scratch[j*2+1]
    if merged>0 and lo<=scratch[(merged-1)*2+1]+1 then scratch[(merged-1)*2+1]=math.max(hi,scratch[(merged-1)*2+1])
    else scratch[merged*2],scratch[merged*2+1]=lo,hi;merged=merged+1 end
  end
  local overflow=0
  -- Only pathological inputs need reduction: discard smallest cavities, never remove roof.
  local allowed=merged>0 and scratch[(merged-1)*2+1]>=h and 4 or 3
  while merged>allowed do
    overflow=overflow+1;local best,size=0,math.huge
    for j=0,merged-1 do local d=scratch[j*2+1]-scratch[j*2];if d<size then best,size=j,d end end
    for j=best,merged-2 do scratch[j*2]=scratch[j*2+2];scratch[j*2+1]=scratch[j*2+3] end
    merged=merged-1
    allowed=merged>0 and scratch[(merged-1)*2+1]>=h and 4 or 3
  end
  for j=0,7 do out[offset+j]=-1 end
  local count,lower=0,0
  for j=0,merged-1 do
    out[offset+count*2]=lower;out[offset+count*2+1]=scratch[j*2];count=count+1;lower=scratch[j*2+1]
  end
  if lower<h or count==0 then out[offset+count*2]=lower;out[offset+count*2+1]=h;count=count+1 end
  return merged>0,overflow,count
end
return C
