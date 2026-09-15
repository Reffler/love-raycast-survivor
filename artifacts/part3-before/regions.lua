-- Canonical global D8 drainage, exact capped accumulation and overlapping halos.
local ffi,G,H=require('ffi'),require('geography'),require('hydrology')
local Fluid,C=require('fluid'),require('river_geometry')
local R={SIZE=1024,STEP=32,FINE=4,CORE=32,CAP=32,HALO=36,CACHE=9,MARGIN=32}
R.__index=R
local N=R.CORE+R.HALO*2+1
local F=(R.SIZE+R.MARGIN*2)/R.FINE+1
R.F=F
function R.new(config)
  local self=setmetatable({config=config,cache={},clock=0,builds=0,cpuSeconds=0,maxBuildSeconds=0,
    height=ffi.new('double[?]',N*N),drainHeight=ffi.new('double[?]',N*N),posX=ffi.new('double[?]',N*N),posY=ffi.new('double[?]',N*N),climate=ffi.new('double[?]',N*N),snowBoundary=ffi.new('double[?]',N*N),rock=ffi.new('double[?]',N*N),
    receiver=ffi.new('int[?]',N*N),flow=ffi.new('uint16_t[?]',N*N),nextFlow=ffi.new('uint16_t[?]',N*N)},R)
  for i=1,R.CACHE do self.cache[i]={x=math.huge,y=math.huge,stamp=0,
    bed=ffi.new('float[?]',F*F),water=ffi.new('float[?]',F*F),wet=ffi.new('float[?]',F*F),snow=ffi.new('float[?]',F*F),snowBoundary=ffi.new('float[?]',F*F),rock=ffi.new('float[?]',F*F)} end
  self.bytes=R.CACHE*F*F*24+N*N*64
  return self
end
function R:find(rx,ry)
  for i=1,R.CACHE do local r=self.cache[i];if r.x==rx and r.y==ry then return r end end
end
local function lerp(a,b,t) return a+(b-a)*t end
function R:build(region,rx,ry)
  local ox,oy=rx*R.SIZE,ry*R.SIZE
  region.fluid={};region.drops={}
  local heights,climate,receiver,flow,nextFlow=self.height,self.climate,self.receiver,self.flow,self.nextFlow
  for y=0,N-1 do
    for x=0,N-1 do
      local i=y*N+x
      heights[i],climate[i]=G.height(self.config,ox+(x-R.HALO)*R.STEP,oy+(y-R.HALO)*R.STEP)
      flow[i]=heights[i]>self.config.SEA_LEVEL and 1 or 0
    end
    coroutine.yield()
  end
  local snowBoundary,rock=self.snowBoundary,self.rock
  -- Material controls need only the raster margin, not the drainage halo.
  for y=R.HALO-2,R.HALO+R.CORE+2 do
    for x=R.HALO-2,R.HALO+R.CORE+2 do
      local i=y*N+x
      local curvature=4*heights[i]-heights[i-1]-heights[i+1]-heights[i-N]-heights[i+N]
      snowBoundary[i],rock[i]=G.material(self.config,ox+(x-R.HALO)*R.STEP,oy+(y-R.HALO)*R.STEP,climate[i],curvature)
    end
    coroutine.yield()
  end
  local drain,posX,posY=self.drainHeight,self.posX,self.posY
  for y=0,N-1 do for x=0,N-1 do
    local gx,gy=rx*R.CORE+x-R.HALO,ry*R.CORE+y-R.HALO
    local px=gx*32+(G.hash(gx,gy,self.config.seed+1901)-0.5)*19
    local py=gy*32+(G.hash(gx,gy,self.config.seed+2003)-0.5)*19
    local fx,fy=px/32,py/32;local ix,iy=math.floor(fx),math.floor(fy)
    local u,v=fx-ix,fy-iy
    local k=math.max(0,math.min(N-2,iy-ry*R.CORE+R.HALO))*N+math.max(0,math.min(N-2,ix-rx*R.CORE+R.HALO))
    local i=y*N+x
    posX[i],posY[i]=px,py
    drain[i]=lerp(lerp(heights[k],heights[k+1],u),lerp(heights[k+N],heights[k+N+1],u),v)
    flow[i]=drain[i]>self.config.SEA_LEVEL and 1 or 0
  end;coroutine.yield() end
  for y=0,N-1 do
    for x=0,N-1 do
      local i=y*N+x;local best,drop=-1,0
      if drain[i]>self.config.SEA_LEVEL then
        for dy=-1,1 do for dx=-1,1 do
          if (dx~=0 or dy~=0) and x+dx>=0 and x+dx<N and y+dy>=0 and y+dy<N then
            local j=(y+dy)*N+x+dx;local slope=(drain[i]-drain[j])/math.sqrt((posX[i]-posX[j])^2+(posY[i]-posY[j])^2)
            if slope>drop then best,drop=j,slope end
          end
        end end
      end
      receiver[i]=best
    end
    coroutine.yield()
  end
  -- CAP iterations are sufficient: an unresolved path already contributes CAP cells.
  -- Core plus raster margin lies more than CAP+1 cells from array boundary.
  if self.config.rivers then
    for pass=1,R.CAP do
      for i=0,N*N-1 do nextFlow[i]=drain[i]>self.config.SEA_LEVEL and 1 or 0 end
      for y=0,N-1 do
        for x=0,N-1 do local i=y*N+x;local j=receiver[i]
          if j>=0 then nextFlow[j]=math.min(R.CAP,nextFlow[j]+flow[i]) end
        end
        if y%8==7 then coroutine.yield() end
      end
      flow,nextFlow=nextFlow,flow
    end
  end
  for y=0,F-1 do
    local gy=(y*R.FINE-R.MARGIN)/R.STEP;local iy=math.floor(gy)+R.HALO;local v=gy-math.floor(gy)
    for x=0,F-1 do
      local gx=(x*R.FINE-R.MARGIN)/R.STEP;local ix=math.floor(gx)+R.HALO;local u=gx-math.floor(gx)
      local k=iy*N+ix;local i=y*F+x
      region.bed[i]=lerp(lerp(heights[k],heights[k+1],u),lerp(heights[k+N],heights[k+N+1],u),v)
      region.snow[i]=lerp(lerp(climate[k],climate[k+1],u),lerp(climate[k+N],climate[k+N+1],u),v)
      region.snowBoundary[i]=lerp(lerp(snowBoundary[k],snowBoundary[k+1],u),lerp(snowBoundary[k+N],snowBoundary[k+N+1],u),v)
      region.rock[i]=lerp(lerp(rock[k],rock[k+1],u),lerp(rock[k+N],rock[k+N+1],u),v)
      region.water[i]=0;region.wet[i]=-1000
    end
    coroutine.yield()
  end
  local hydrology=H.new(self.config,self,rx,ry,N,R.HALO)
  local function carve(path,lake)
    local width=lake and lake.width or C.width(path.amount)
    local valley=width*2+8
    local minx=math.max(0,math.floor(((lake and lake.x or path.minx)-valley+R.MARGIN)/4))
    local maxx=math.min(F-1,math.ceil(((lake and lake.x or path.maxx)+valley+R.MARGIN)/4))
    local miny=math.max(0,math.floor(((lake and lake.y or path.miny)-valley+R.MARGIN)/4))
    local maxy=math.min(F-1,math.ceil(((lake and lake.y or path.maxy)+valley+R.MARGIN)/4))
    for y=miny,maxy do for x=minx,maxx do
      local px,py=x*4-R.MARGIN,y*4-R.MARGIN
      local distance,t
      if lake then distance,t=C.lakeDistance(lake,px,py),0 else distance,t=C.distance(path,px,py) end
      local level=lake and lake.level or path.kind and (t<=path.lip and path.upper or path.lower) or path.upper
      local channel=width
      if not lake and path.headwater then channel=width*(0.5+0.5*G.smooth(t*path.length/(width*2))) end
      if distance<valley then
        local i=y*F+x;local h=region.bed[i]
        local cut=G.smooth((valley-distance)/(valley-channel))
        local profile=G.smooth(1-distance/channel)
        if level<=self.config.SEA_LEVEL then
          -- Existing sea-level cross-section is retained at mouths.
          region.bed[i]=math.min(h,lerp(h,level-1-(2+math.sqrt(path and path.amount or lake.amount)*0.65)*profile,cut))
        elseif distance<=channel then
          local depth=2+math.min(3,math.sqrt(path and path.amount or lake.amount)*0.5)*profile
          region.bed[i]=math.min(h,level-depth)
        elseif region.wet[i]<=0 then
          local shoulder=level+(lake and 0 or 1)
          region.bed[i]=lerp(h,shoulder,cut)
          if distance-channel<3 then region.bed[i]=math.max(region.bed[i],shoulder) end
        end
        local wet=channel-distance
        if wet>region.wet[i] or wet==region.wet[i] and level<region.water[i] then region.wet[i]=wet;region.water[i]=level end
      end
    end;coroutine.yield() end
  end
  local paths,lakes={},{}
  region.lakes,region.paths=lakes,paths
  if self.config.rivers then
    for y=-3,R.CORE+3 do
      for x=-3,R.CORE+3 do
        local i=(y+R.HALO)*N+x+R.HALO;local j=receiver[i];local amount=flow[i]
        if amount>=8 and drain[i]>self.config.SEA_LEVEL then
          local node=hydrology:resolve(rx*R.CORE+x,ry*R.CORE+y)
          local level=H.level(node)
          local ax,ay=posX[i]-ox,posY[i]-oy
          if j>=0 then
            local bx,by=posX[j]-ox,posY[j]-oy
            local downstream=hydrology:resolve(rx*R.CORE+x+(j%N-i%N),ry*R.CORE+y+(math.floor(j/N)-math.floor(i/N)))
            local tx,ty=hydrology:tangent(node);local ux,uy=hydrology:tangent(downstream)
            local headwater=true
            for dy=-1,1 do for dx=-1,1 do
              local parent=i+dy*N+dx
              if receiver[parent]==i and flow[parent]>=8 then headwater=false end
            end end
            paths[#paths+1]=C.curve({ax=ax,ay=ay,bx=bx,by=by,upper=level,lower=H.level(downstream),amount=amount,
              tx=tx,ty=ty,ux=ux,uy=uy,headwater=headwater},self.config.seed,ox,oy)
          else
            lakes[#lakes+1]=C.lake({x=ax,y=ay,level=node.base,width=9+math.sqrt(amount)*2,amount=amount},self.config.seed,ox,oy)
            local rim,outlet=hydrology:outlet(node)
            if outlet then
              paths[#paths+1]=C.curve({ax=ax,ay=ay,mx=rim.px-ox,my=rim.py-oy,bx=outlet.px-ox,by=outlet.py-oy,
                upper=node.base,lower=node.base,amount=amount,lake=true},self.config.seed,ox,oy)
            end
          end
          coroutine.yield()
        end
      end
      coroutine.yield()
    end
  end
  -- Read untouched global support, so carve order and categorical reach levels
  -- cannot hide a cliff. Only actual lake/ocean surfaces count as water support.
  local function support(x,y)
    local fx,fy=x/32,y/32;local ix,iy=math.floor(fx),math.floor(fy)
    local u,v=fx-ix,fy-iy;local k=(iy+R.HALO)*N+ix+R.HALO
    local h=lerp(lerp(heights[k],heights[k+1],u),lerp(heights[k+N],heights[k+N+1],u),v)
    local water=h<self.config.SEA_LEVEL and self.config.SEA_LEVEL or 0
    for _,lake in ipairs(lakes) do
      if C.lakeDistance(lake,x,y)<lake.width then water=math.max(water,lake.level) end
    end
    return h,water
  end
  for _,lake in ipairs(lakes) do carve(nil,lake) end
  for _,path in ipairs(paths) do
    local drop=Fluid.outlet(path,support)
    if drop then
      region.drops[#region.drops+1]=drop
    end
    if not path.lake or drop then
      carve(path)
    end
    coroutine.yield()
  end
  Fluid.build(region,self.config,rx,ry,F,R.MARGIN)
  region.hasFluid=next(region.fluid)~=nil
  self.lastHydrologyNodes=hydrology.count
  region.x,region.y=rx,ry
  self.clock=self.clock+1;region.stamp=self.clock
end
function R:request(rx,ry)
  local r=self:find(rx,ry)
  if r then self.clock=self.clock+1;r.stamp=self.clock;return r end
  if not self.job then self:start(rx,ry) end
end
function R:start(rx,ry)
  local slot=self.cache[1]
  for i=2,R.CACHE do if self.cache[i].stamp<slot.stamp then slot=self.cache[i] end end
  slot.x,slot.y=math.huge,math.huge
  self.job=coroutine.create(function() self:build(slot,rx,ry) end)
  self.jobSeconds=0
end

function R:advance(seconds)
  local start=os.clock()
  repeat
    if not self.job then return end
    local t=os.clock();local ok,err=coroutine.resume(self.job);local elapsed=os.clock()-t
    assert(ok,err);self.cpuSeconds=self.cpuSeconds+elapsed;self.jobSeconds=self.jobSeconds+elapsed
    if coroutine.status(self.job)=='dead' then
      self.builds=self.builds+1;self.maxBuildSeconds=math.max(self.maxBuildSeconds,self.jobSeconds);self.job=nil
    end
  until os.clock()-start>=seconds
end
function R:get(rx,ry)
  local r=self:request(rx,ry)
  while not r do self:advance(math.huge);r=self:request(rx,ry) end
  return r
end
return R
