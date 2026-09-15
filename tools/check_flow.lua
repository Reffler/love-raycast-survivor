local ffi,Fluid,Regions,Terrain=require('ffi'),require('fluid'),require('regions'),require('terrain')
local F,M=Regions.F,Regions.MARGIN
local function build(rx,escape)
  local r={fluid={},drops={{ax=-8-rx*1024,ay=512,mx=-rx*1024,my=512,bx=8-rx*1024,by=512,upper=102,lower=78,amount=8,lip=0.5}}}
  for _,name in ipairs({'bed','water','wet','snow'}) do r[name]=ffi.new('float[?]',F*F) end
  for y=0,F-1 do for x=0,F-1 do
    local k=y*F+x;r.bed[k]=escape and x*4-M+rx*1024>=4 and 65 or 77
    r.water[k]=escape and 0 or 78;r.wet[k]=escape and -1000 or 10;r.snow[k]=140
  end end
  local job=coroutine.create(function() Fluid.build(r,{SEA_LEVEL=48},rx,0,F,M) end)
  repeat local ok,err=coroutine.resume(job);assert(ok,err) until coroutine.status(job)=='dead'
  return r
end
local a,b=build(0),build(-1)
local states={};local flowCount=0
for y=496,528 do for x=-16,16 do
  local c,d=a.fluid[Fluid.key(x,y)],b.fluid[Fluid.key(x+1024,y)]
  assert((c==nil)==(d==nil),'Fluid presence changes across region seam')
  if c then
    for _,name in ipairs({'top','bed','bank','floor','state'}) do assert(c[name]==d[name],'Fluid geometry changes across region seam: '..name) end
    if c.state and c.state>=1 and c.state<=7 then
      states[c.state]=true;flowCount=flowCount+1
      assert(math.abs(x)+math.max(0,math.abs(y-512)-2)<=7,'Landing spread escaped bounded radius')
      assert(c.top==79-c.state/8,'Flow lost eighth-block decrement')
    end
  end
end end
for i=1,7 do assert(states[i],'Missing FLOW_'..i) end
local source=a.fluid[Fluid.key(0,512)]
assert(source.state==Fluid.FALLING and source.top==102 and source.bed==nil and source.floor==77,'Discontinuous waterfall column')
assert(flowCount>7,'Landing failed to spread laterally')
local descending=build(0,true);local low=false
for _,c in pairs(descending.fluid) do if c.top and c.top<77 then low=true end end
assert(low,'Water did not descend into nearby escape')
-- Same cached geometry must reach scalar collision and bulk generation identically.
local t=Terrain.new(1337);local region=t.regions:get(0,0)
local data,surface=ffi.new('uint16_t[256]'),ffi.new('uint16_t[256]')
for _,d in ipairs(region.drops) do if d.x>=0 and d.x<1024 then
  for cy=math.floor((d.y-8)/16),math.floor((d.y+8)/16) do
    for cx=math.floor((d.x-8)/16),math.floor((d.x+8)/16) do
      t:generate(cx,cy,data,surface)
      for i=0,255 do
        local h,code=t:height(cx*16+i%16,cy*16+math.floor(i/16))
        assert(h==data[i] and code==surface[i],'Flow chunk/scalar disagreement')
      end
    end
  end
end end
print('PASS: FULL/FLOW_1..7/FALLING, bounded fan, downward escape, exact fluid region seam, flow chunk/scalar agreement')
