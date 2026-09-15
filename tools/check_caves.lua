local ffi,C,W=require('ffi'),require('caves'),require('world')
local scratch,out=C.newScratch(),ffi.new('int16_t[8]')
-- Capsule analytic interval versus independent closest-point distance samples.
for _,p in ipairs({C.capsule(0,0,10,20,10,30,5),C.capsule(0,0,10,0,0,40,5),C.capsule(-20,5,18,20,5,18,4)}) do
  for x=-24,24,3 do for y=-8,18,3 do
    local lo,hi=C.interval(p,x,y,0.5)
    for z=0,50 do
      local vx,vy,vz=p.bx-p.ax,p.by-p.ay,p.bz-p.az
      local t=math.max(0,math.min(1,((x-p.ax)*vx+(y-p.ay)*vy+(z-p.az)*vz)/(vx*vx+vy*vy+vz*vz)))
      local d=(x-p.ax-t*vx)^2+(y-p.ay-t*vy)^2+(z-p.az-t*vz)^2
      if math.abs(d-p.r^2)>1e-7 then assert((lo~=nil and z>lo and z<hi)==(d<p.r^2),'Analytic capsule intersection mismatch') end
    end
  end end
end
local bin={};for z=10,90,15 do bin[#bin+1]=C.capsule(0,0,z,0,0,z,3) end
local _,overflow,count=C.column(bin,0,0,110,false,0.5,out,0,scratch)
assert(overflow>0 and count<=4,'Overflow was silent')
assert(C.protectedHeight(100,0,-2,76,48)==68,'Tall dry bank lacks water-relative protection')
assert(C.protectedHeight(70,608,1,76,48)==70,'Wet bed protection wrong')
assert(C.protectedHeight(60,0,-1000,0,48)==40,'Ocean bank protection wrong')
print('PASS: exact capsule math, vertical/diagonal axes, explicit overflow reduction')
local sampled,complex=0,0
for _,seed in ipairs({1337,716701,452312,42}) do
  local w=W.new(seed,16);local comparison=W.new(seed,16)
  -- Full 1024x1024 region per seed, plus negative / adjacent region boundary chunks.
  for cy=-32,31 do for cx=-32,31 do
    local c=w:generateChunk(cx,cy)
    if c.complex then complex=complex+1 end
    for i=0,255 do
      if c.complex then
        local k=i*8;local last=-1
        for j=0,3 do
          local lo,hi=c.spans[k+j*2],c.spans[k+j*2+1]
          if lo<0 then for m=j,3 do assert(c.spans[k+m*2]==-1 and c.spans[k+m*2+1]==-1) end;break end
          assert(lo>=0 and hi>lo and lo>last and hi<=c.data[i],'Corrupt solid spans');last=hi
        end
        if c.surface[i]%2048>0 then
          assert(last==c.data[i],'Wet surface roof removed')
          for j=0,2 do if c.spans[k+j*2+2]>=0 then assert(c.spans[k+j*2+2]<=c.data[i]-C.WATER_ROOF,'Water roof too thin') end end
        end
      end
      sampled=sampled+1
    end
    if cx%16==0 and cy%16==0 then
      for _,i in ipairs({0,15,240,255,119}) do
        local x,y=cx*16+i%16,cy*16+math.floor(i/16)
        local a,n,changed=comparison.terrain:spansAt(x,y)
        assert(changed==((c.complex and c.spans[i*8+2]>=0) or (c.complex and c.spans[i*8+1]<c.data[i])),'Scalar complexity disagreement')
        if c.complex then for j=0,7 do assert(a[j]==c.spans[i*8+j],'Bulk/scalar span mismatch') end end
        for z=0,254,7 do
          local expected=false;for j=0,n-1 do if z>=a[j*2] and z<a[j*2+1] then expected=true end end
          assert(w:isSolid(x,y,z)==expected,'Cached/fallback solidity mismatch')
        end
      end
    end
  end end
  assert(w.terrain.spanOverflowCount==0,'Natural cave overflow seed '..seed)
  for _,p in ipairs({{-65,-65},{-64,-64},{-1,-1},{0,0},{63,63},{64,64},{62500,-62500}}) do
    local cx,cy=unpack(p);local a=w:generateChunk(cx,cy);local bytes=ffi.string(a.spans,4096);local flag=a.complex
    comparison:generateChunk(cx+128,cy-128);local b=comparison:generateChunk(cx,cy)
    assert(flag==b.complex and (not flag or bytes==ffi.string(b.spans,4096)),'Seam/order/far-coordinate mismatch')
  end
  local left=w.terrain.regions:get(-1,0);local right=w.terrain.regions:get(0,0)
  local otherOut=ffi.new('int16_t[8]')
  for y=0,1024,7 do
    local h,code=w.terrain:height(0,y)
    C.column(left.cavePrimitives,0,y,h,code%2048>0,0.5,out,0,scratch)
    C.column(right.cavePrimitives,0,y,h,code%2048>0,0.5,otherOut,0,scratch)
    assert(ffi.string(out,16)==ffi.string(otherOut,16),'Independent regional primitive seam mismatch')
  end
  print('PASS seed '..seed..': full region survey, bulk/scalar, negative/macro seams, eviction, water roofs; zero overflows')
end
print(('PASS: %d columns surveyed, %d complex chunks'):format(sampled,complex))
