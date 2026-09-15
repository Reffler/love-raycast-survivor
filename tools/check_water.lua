local Terrain,Regions,H,G=require('terrain'),require('regions'),require('hydrology'),require('geography')
local function run(fn)
  local job=coroutine.create(fn)
  while coroutine.status(job)~='dead' do local ok,err=coroutine.resume(job);assert(ok,err) end
end
-- A destination beyond the old halo must still resolve to the actual ocean.
local original=G.height
G.height=function(_,x,y) return 48+x/320,140 end
local ocean=H.new({seed=19,SEA_LEVEL=48},{},0,0,0,0)
run(function()
  local node=ocean:resolve(160,0)
  assert(node.ocean and H.level(node)==48,'Long ocean tributary acquired an inland level')
end)
G.height=original
local oceans,lakes,drops=0,0,0
local transitionEdges=0
for _,seed in ipairs({1337,42,9187,65168,716701,452312,5,26,33}) do
  local t=Terrain.new(seed);local r=t.regions;local region=r:get(0,0)
  local N=Regions.CORE+Regions.HALO*2+1
  local h=H.new(t.settings,r,0,0,N,Regions.HALO)
  run(function()
    for y=0,32 do for x=0,32 do
      local i=(y+Regions.HALO)*N+x+Regions.HALO
      if r.flow[i]>=8 and r.drainHeight[i]>48 then
        local node=h:resolve(x,y);local level=H.level(node)
        if node.ocean then assert(level==48);oceans=oceans+1
        else assert(node.lakeWaterLevel==node.base);lakes=lakes+1 end
        local j=r.receiver[i]
        if j<0 and node.px>=0 and node.py>=0 and node.px<1024 and node.py<1024 then
          local _,_,water=t:height(math.floor(node.px),math.floor(node.py))
          assert(water==node.lakeWaterLevel,'Lake center disagrees with basin spill level')
        end
        if j>=0 then
          local other=h:resolve(j%N-Regions.HALO,math.floor(j/N)-Regions.HALO)
          local nextLevel=H.level(other)
          assert(nextLevel<=level,'Water reach rises downstream')
          assert(node.base==other.base,'Connected reaches disagree about basin level')
          if nextLevel~=level then assert((level-nextLevel)%24==0);drops=drops+1 end
        end
      end
    end end
  end)
  local Fluid=require('fluid')
  local bankErrors=0
  for y=0,1023 do for x=0,1023 do
    local bed,_,water=t:height(x,y)
    assert(water==0 or water>bed and water*8==math.floor(water*8))
    if water>t.settings.SEA_LEVEL then
      for dy=-1,1 do for dx=-1,1 do if dx~=0 or dy~=0 then
        local otherBed,_,other=t:height(x+dx,y+dy)
        if (dx==0 or dy==0) and other>0 and math.abs(other-water)>1 then
          transitionEdges=transitionEdges+1
          local near=false
          -- Landing spread may fall again, bounded to fourteen D4 steps.
          for _,d in ipairs(region.drops) do for _,face in ipairs(d.faces or {}) do
            if math.abs(x-face.x)+math.abs(y-face.y)<=16 then near=true end
          end end
          assert(near,('Tall water face seed%d %d,%d top%g -> %d,%d top%g'):format(seed,x,y,water,x+dx,y+dy,other))
        end
        if other==0 and otherBed<water then
          bankErrors=bankErrors+1
          if bankErrors<4 then print(('BANK seed%d %d,%d water%g -> %d,%d bed%d'):format(seed,x,y,water,x+dx,y+dy,otherBed)) end
        end
      end end end
    end
  end end
  assert(bankErrors==0,('Submerged dry shoreline: %d'):format(bankErrors))
  local flowing,falling=0,0
  for key,c in pairs(region.fluid) do
    if c.top and c.top%1~=0 then flowing=flowing+1 end
    if c.state==Fluid.FALLING then falling=falling+1 end
  end
  print(('PASS seed %d: shoreline invariant; %d flow cells, %d falling columns'):format(seed,flowing,falling))

end
assert(oceans>0 and lakes>0 and drops>0,'Missing ocean/lake/drop coverage')
local _,_,inland=Terrain.new(1337):finish(44,0,60,4,140,0.5)
assert(inland==60,'Sub-sea bed overwrote inland water level')
print(('PASS: beyond-halo ocean connectivity; %d ocean nodes, %d inland nodes, %d explicit reach drops; source levels and submerged beds'):format(oceans,lakes,drops))
print(('PASS: eighth-block water heights, dry-bank invariant; %d tall neighbor faces confined to narrow lips'):format(transitionEdges))
