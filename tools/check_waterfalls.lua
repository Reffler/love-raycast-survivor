package.path='tools/?.lua;'..package.path
local ffi,Fluid,Terrain,Fixtures=require('ffi'),require('fluid'),require('terrain'),require('waterfall_fixtures')
local function check(drop,cliff,lake)
  local rx=math.floor(cliff/1024);local r,d=Fixtures.region(drop,cliff,rx,0,lake)
  assert(d.upper==d.reachLower,'Fixture does not test identical level metadata')
  assert(d.kind==(drop==1 and 'ramp' or 'fall') and d.lower==72-drop,'Wrong support-driven state')
  local falling,flow=0,0
  for key,c in pairs(r.fluid) do
    local x,y=key%1152-64,math.floor(key/1152)-64
    if c.state==Fluid.FALLING then
      falling=falling+1
      assert(math.abs(x-d.x)<=3 and math.abs(y-d.y)<=d.width,'Fall escaped outlet onto perimeter')
      assert(c.top==72 and c.bed==nil and c.floor==71-drop,'Fall does not reach support')
    elseif c.state and c.state>=1 and c.state<=7 then flow=flow+1 end
  end
  assert(drop==1 and falling==0 and flow>=7 or drop>1 and falling>=1 and falling==d.width and flow>7,'Missing ramp/fall/landing fan')
  local cache={};local t=Terrain.new(1337,{SEA_LEVEL=1,OCEAN_FLOOR=0})
  t.regions={get=function(_,x,y)
    local key=x..','..y
    if not cache[key] then cache[key]=Fixtures.region(drop,cliff,x,y,lake) end
    return cache[key]
  end}
  local data,codes=ffi.new('uint16_t[256]'),ffi.new('uint16_t[256]')
  for cx=math.floor((cliff-8)/16),math.floor((cliff+8)/16) do for cy=31,32 do
    t:generate(cx,cy,data,codes)
    for i=0,255 do
      local h,code=t:height(cx*16+i%16,cy*16+math.floor(i/16))
      assert(h==data[i] and code==codes[i],'Waterfall chunk/scalar seam')
    end
  end end
  -- Centerline stays wet through lip, fall and downstream landing/ramp.
  for x=cliff-48,cliff+16 do
    local h,_,water=t:height(x,512);assert(water>h,'Gap in waterfall/outlet centerline')
  end
  if lake then
    local _,_,water=t:height(cliff-12,520)
    assert(water==72,'Outlet narrowing drained lake interior')
  end
  local a=Fixtures.region(drop,cliff,rx-1,0,lake)
  for y=504,520 do for x=rx*1024-4,rx*1024+4 do
    local ah,ac=t:column(a,x-(rx-1)*1024,y,0.5)
    local bh,bc=t:column(r,x-rx*1024,y,0.5)
    assert(ah==bh and ac==bc,'Macro overlap changed fluid geometry')
  end end
  -- Rebuild after another region and different generation order.
  Fixtures.region(drop,cliff,rx+1,1,lake)
  local again=Fixtures.region(drop,cliff,rx,0,lake)
  for key,c in pairs(r.fluid) do for _,field in ipairs({'top','bed','bank','floor','state'}) do
    assert(again.fluid[key] and c[field]==again.fluid[key][field],'Generation order changed fluid state')
  end end
  print(('PASS: %d-block %s at x=%d, equal metadata; %d falling columns, %d flow cells; connected chunks/regions and exact rebuild'):format(drop,lake and 'lake outlet' or 'river',cliff,falling,flow))
end
check(40,16,false)
check(40,16,true)
check(1,16,false)
check(20,16,false)
check(40,1024,false)
check(40,0,true)
-- Actual generated basins exercise the same-level path through Regions, not
-- only fixtures. Seed 33 places its outlet beside a macro/chunk boundary.
for _,seed in ipairs({5,26,33}) do
  local t=Terrain.new(seed);local r=t.regions:get(0,0);local found=false
  for _,d in ipairs(r.drops) do
    if d.lake and d.reachLower==d.upper and d.kind=='fall' and d.x>=0 and d.x<1024 and d.y>=0 and d.y<1024 then
      found=true
      for _,face in ipairs(d.faces) do
        local h,_,water=t:height(face.x,face.y)
        assert(water>=d.upper and h<d.upper,('Natural outlet lacks falling volume seed%d %d,%d h%g top%g upper%g'):format(seed,face.x,face.y,h,water,d.upper))
        local bh,_,bw=t:height(face.bx,face.by)
        assert(bh>=face.backing and bw>=d.upper,'Missing solid backing/lip connector')
      end
    end
  end
  assert(found,'Natural same-level outlet regression: '..seed)
  local reordered=Terrain.new(seed);reordered.regions:get(1,0)
  local copy=reordered.regions:get(0,0)
  for key,c in pairs(r.fluid) do for _,field in ipairs({'top','bed','bank','floor','state'}) do
    assert(copy.fluid[key] and copy.fluid[key][field]==c[field],'Natural generation order changed fluid geometry')
  end end
  for key in pairs(copy.fluid) do assert(r.fluid[key],'Natural generation order added fluid geometry') end
  local left=t.regions:get(-1,0)
  for y=0,1023 do for x=-2,2 do
    local h,code=t:column(r,x,y,0.5);local hh,cc=t:column(left,x+1024,y,0.5)
    assert(h==hh and code==cc,'Natural fluid macro seam: '..seed)
  end end
  print('PASS: actual equal-metadata lake outlet and exact macro seam, seed '..seed)
end
