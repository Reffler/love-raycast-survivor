local ffi=require('ffi')
local Terrain,Regions=require('terrain'),require('regions')
local fields={'bed','water','wet','snow','snowBoundary','rock'}
local F=Regions.F;local M=Regions.MARGIN/4
for _,seed in ipairs({1337,42,9187}) do
  local t=Terrain.new(seed)
  local a=t.regions:get(0,0);local b=t.regions:get(1,0);local c=t.regions:get(0,-1)
  local wet=0
  for i=0,256 do for _,field in ipairs(fields) do
    assert(a[field][(i+M)*F+256+M]==b[field][(i+M)*F+M],('X regional seam seed %d field %s row %d'):format(seed,field,i))
    assert(a[field][M*F+i+M]==c[field][(256+M)*F+i+M],('Y regional seam seed %d field %s col %d'):format(seed,field,i))
    if field=='wet' and a[field][(i+M)*F+256+M]>0 then wet=wet+1 end
  end end
  -- Independent generation order and resumable macro build must preserve all controls.
  local other=Terrain.new(seed);other.regions:get(2,2)
  other.regions:request(0,0)
  while not other.regions:find(0,0) do other:advance(0.00001) end
  local copy=other.regions:get(0,0)
  for _,field in ipairs(fields) do assert(ffi.string(a[field],F*F*4)==ffi.string(copy[field],F*F*4),'Macro timing/order changed controls') end
  local negative=t.regions:get(-1,-1);local right=t.regions:get(0,-1);local below=t.regions:get(-1,0)
  for i=0,256 do for _,field in ipairs(fields) do
    assert(negative[field][(i+M)*F+256+M]==right[field][(i+M)*F+M],'Negative X seam')
    assert(negative[field][(256+M)*F+i+M]==below[field][M*F+i+M],'Negative Y seam')
  end end
  local data,surface=ffi.new('uint16_t[256]'),ffi.new('uint16_t[256]')
  for _,position in ipairs({{-1,-1},{0,0},{63,63},{64,64},{-65,3},{125,17}}) do
    local cx,cy=unpack(position);t:generate(cx,cy,data,surface)
    for y=0,15 do for x=0,15 do
      local h,code=t:height(cx*16+x,cy*16+y)
      assert(h==data[y*16+x] and code==surface[y*16+x],('Bulk/scalar seam %d %d'):format(cx*16+x,cy*16+y))
    end end
  end
  print(('PASS seed %d: exact regional controls/seams (%d wet edge points), timing/order, chunk/scalar agreement'):format(seed,wet))
end
-- Inspect the globally shared drainage graph in a freshly generated region.
local riverEdges,merges,sinks,ocean=0,0,0,0
for _,seed in ipairs({1337,42,9187}) do
  local t=Terrain.new(seed);local r=t.regions
  r:get(0,0)
  local N=Regions.CORE+Regions.HALO*2+1
  for y=Regions.HALO,Regions.HALO+Regions.CORE do for x=Regions.HALO,Regions.HALO+Regions.CORE do
    local i=y*N+x;local j=r.receiver[i]
    if j>=0 then
      assert(r.drainHeight[j]<r.drainHeight[i],'River flows uphill')
      assert(r.flow[j]>=r.flow[i],'Capped flow decreased downstream')
      if r.flow[i]>=8 then
        riverEdges=riverEdges+1
        local ax,ay,bx,by=r.posX[i],r.posY[i],r.posX[j],r.posY[j]
        if ax>32 and ay>32 and bx>32 and by>32 and ax<992 and ay<992 and bx<992 and by<992 then
          local C=require('river_geometry')
          local path
          for _,candidate in ipairs(r:get(0,0).paths) do
            if candidate.ax==ax and candidate.ay==ay and candidate.bx==bx and candidate.by==by then path=candidate;break end
          end
          assert(path,'Missing rendered drainage edge')
          for sample=0,math.ceil(path.length) do
            local xx,yy=C.at(path,sample/math.ceil(path.length));xx,yy=math.floor(xx),math.floor(yy)
            local height,_,water=t:height(xx,yy)
            assert(water>height,('Dry curved centerline seed%d %d,%d t%g drop%s'):format(seed,xx,yy,sample/path.length,tostring(path.kind)))
          end
        end
      end
    elseif r.flow[i]>=8 then
      if r.drainHeight[i]<=t.settings.SEA_LEVEL then ocean=ocean+1 else sinks=sinks+1 end
    end
    local parents=0
    for dy=-1,1 do for dx=-1,1 do if r.receiver[(y+dy)*N+x+dx]==i then parents=parents+1 end end end
    if parents>=2 and r.flow[i]>=8 then merges=merges+1 end
  end end
end
assert(riverEdges>0 and merges>0 and sinks+ocean>0,'Missing drainage topology')
print(('PASS: downhill/capped monotone accumulation, %d river edges, %d confluences, %d sinks, %d ocean outlets'):format(riverEdges,merges,sinks,ocean))

local t=Terrain.new(1337)
local function material(h,slope,snow)
  local _,code=t:finish(h,slope,0,-1000,snow or 140,0.5)
  return math.floor(code/2048)
end
assert(material(50,0.1)==1,'Gentle coast missing sand')
assert(material(50,1.1)==2,'Cliff coast gained beach')
assert(material(52,0.1,130)==0 and material(52,0.1,155)==1,'Beach width does not vary')
assert(material(75,0.1)==0 and material(8,0.1)==4,'Lowland/ocean materials wrong')
assert(material(180,0.5)==3 and material(180,2)==2,'Snow or steep rock classification wrong')
print('PASS: gentle beaches, variable beach width, cliff exclusion, grass/dirt, altitude/climate snow and steep rock')
