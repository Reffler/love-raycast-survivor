package.path='tools/?.lua;'..package.path
local T,C,F,Fixtures=require('terrain'),require('river_geometry'),require('fluid'),require('waterfall_fixtures')
local offsets={{1,0},{-1,0},{0,1},{0,-1}}
local function connected(t,d)
  -- Flood water occupancy at the upper surface, rather than trusting records.
  local sx,sy=C.at(d,math.max(0,d.lip-0.25));sx,sy=math.floor(sx),math.floor(sy)
  local queue,seen={{sx,sy}},{[F.key(sx,sy)]=true};local head=1
  while head<=#queue do
    local p=queue[head];head=head+1
    for _,v in ipairs(offsets) do
      local x,y=p[1]+v[1],p[2]+v[2];local k=F.key(x,y)
      if not seen[k] and x>=d.minx-16 and x<=d.maxx+16 and y>=d.miny-16 and y<=d.maxy+16 then
        local h,_,w=t:height(x,y)
        if h<d.upper and w>=d.upper then seen[k]=true;queue[#queue+1]={x,y} end
      end
    end
  end
  for _,face in ipairs(d.faces) do
    local h,_,w=t:height(face.x,face.y)
    local bh,_,bw=t:height(face.bx,face.by)
    assert(seen[F.key(face.x,face.y)],('Feeder gap at %d,%d upper%g lip%d,%d'):format(face.x,face.y,d.upper,d.x,d.y))
    assert(bh>=face.backing and bh<d.upper and bw>=d.upper,'Cliff backing/lip missing')
    assert(h<d.upper and w>=d.upper,'Vertical water occupancy missing')
    local landing=false
    for _,v in ipairs(offsets) do
      local lh,_,lw=t:height(face.x+v[1],face.y+v[2])
      if lw>lh and lh<w and lw>h and lh<d.upper-1 then landing=true end
    end
    assert(landing,('Landing gap at %d,%d bottom%g'):format(face.x,face.y,h))
  end
end
local last=0
for _,amount in ipairs({1,8,32,128}) do
  local r,d=Fixtures.region(40,1024,1,0,false,amount)
  assert(d.width>last and #d.faces==d.width,'Fall width does not scale with channel');last=d.width
  local t=T.new(1337,{SEA_LEVEL=1,OCEAN_FLOOR=0})
  local cache={}
  t.regions={get=function(_,rx,ry) local key=rx..','..ry;if not cache[key] then cache[key]=Fixtures.region(40,1024,rx,ry,false,amount) end;return cache[key] end}
  -- Fixture uses local geometry, translated back to world for occupancy checks.
  local localT={height=function(_,x,y) return t:height(x+1024,y) end}
  connected(localT,d)
  for _,face in ipairs(d.faces) do
    local c=r.fluid[F.key(face.x,face.y)]
    assert(c.bed==nil and c.floor==31,'Falling record excavated terrain')
  end
end
print('PASS: 2/4/6/8-column falls; intact backing, feeder and landing occupancy across macro/chunk boundary')
for _,angle in ipairs({math.pi/2,math.pi/4,-0.73}) do
  for _,amount in ipairs({8,32}) do
    local r,d=Fixtures.region(40,1024,1,0,false,amount,angle)
    local t=T.new(1337,{SEA_LEVEL=1,OCEAN_FLOOR=0});local cache={}
    t.regions={get=function(_,rx,ry)
      local key=rx..','..ry
      if not cache[key] then cache[key]=Fixtures.region(40,1024,rx,ry,false,amount,angle) end
      return cache[key]
    end}
    connected({height=function(_,x,y) return t:height(x+1024,y) end},d)
    assert(#d.faces>=d.width*0.65,'Diagonal sheet collapsed to single column')
    local left=Fixtures.region(40,1024,0,0,false,amount,angle)
    for y=496,528 do for x=-4,4 do
      local h,c=t:column(r,x,y,0.5);local hh,cc=t:column(left,x+1024,y,0.5)
      assert(h==hh and c==cc,'Rotated waterfall macro seam')
    end end
  end
end
print('PASS: vertical/diagonal/oblique cliff sheets, continuous lanes and exact macro overlap')
local checked,curved,deep,banks=0,0,0,0
for _,seed in ipairs({1337,42,9187,5,26,33}) do
  local t=T.new(seed);local r=t.regions:get(0,0)
  for _,d in ipairs(r.drops) do
    if d.kind=='fall' and d.x>=0 and d.x<1024 and d.y>=0 and d.y<1024 then connected(t,d);checked=checked+1 end
  end
  for _,p in ipairs(r.paths) do
    local a,b=p.points[1],p.points[#p.points]
    assert(math.abs(a.x-p.ax)<1/65536 and math.abs(a.y-p.ay)<1/65536 and math.abs(b.x-p.bx)<1/65536 and math.abs(b.y-p.by)<1/65536,'Curve moved drainage endpoint')
    local bend=0;local dx,dy=p.bx-p.ax,p.by-p.ay;local length=math.sqrt(dx*dx+dy*dy)
    for i=2,#p.points do
      local q,prev=p.points[i],p.points[i-1]
      assert(q.s-prev.s<4.5,'Curve sampling too coarse')
      bend=math.max(bend,math.abs((q.x-p.ax)*dy-(q.y-p.ay)*dx)/length)
    end
    if bend>0.25 then curved=curved+1 end
    if not p.kind and not p.lake and not p.headwater and p.upper>48 then
      local x,y,dx,dy=C.at(p,0.5)
      if x>32 and x<992 and y>32 and y<992 then
        local h,_,w=t:height(math.floor(x),math.floor(y))
        if w==p.upper then assert(w-h>=2,'Ordinary channel lacks center depth');deep=deep+1 end
        for _,sign in ipairs({-1,1}) do
          local offset=(C.width(p.amount)+2)*sign
          local bh,_,bw=t:height(math.floor(x-dy*offset),math.floor(y+dx*offset))
          if bw==0 then assert(bh>=p.upper+1,'Ordinary shoulder flush with water');banks=banks+1 end
        end
      end
    end
    if p.tx then
      for _,nextPath in ipairs(r.paths) do
        if nextPath.ax==p.bx and nextPath.ay==p.by and nextPath.tx then
          assert(p.ux==nextPath.tx and p.uy==nextPath.ty,'Consecutive curves lack shared tangent')
        end
      end
    end
  end
end
assert(checked>0 and curved>100,'Missing natural geometry coverage')
print(('PASS: %d natural waterfalls continuously connected; %d curved edges, sub-block endpoint tolerance and bounded sampling'):format(checked,curved))
assert(deep>200 and banks>300,'Missing recessed channel coverage')
print(('PASS: %d recessed channel centers, %d raised bank shoulders and shared drainage tangents'):format(deep,banks))
local lake=C.lake({x=500,y=500,width=20},1337,0,0)
local lo,hi=math.huge,0
for i=0,63 do
  local angle=i*math.pi/32
  local distance=C.lakeDistance(lake,500+math.cos(angle)*20,500+math.sin(angle)*20)
  lo,hi=math.min(lo,distance),math.max(hi,distance)
end
assert(hi-lo>5 and lo<20 and hi>20,'Lake outline remains a disc')
print('PASS: deterministic warped lake shoreline crosses nominal circle in both directions')
