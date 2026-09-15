-- Controlled terrain goes through the production outlet detector and fluid builder.
local ffi,Fluid,Regions,H=require('ffi'),require('fluid'),require('regions'),require('hydrology')
local Fixtures={}
local function run(fn)
  local job=coroutine.create(fn)
  repeat local ok,err=coroutine.resume(job);assert(ok,err) until coroutine.status(job)=='dead'
end
function Fixtures.lakeOutlet()
  local h=H.new({SEA_LEVEL=48},{},0,0,0,0);local nodes={}
  function h:node(x,y)
    local key=x..','..y
    if not nodes[key] then
      local height=x==0 and y==0 and 68 or x==1 and y==0 and 72 or x==2 and y==0 and 31 or 90
      nodes[key]={x=x,y=y,px=x*8,py=y*8,height=height}
    end
    return nodes[key]
  end
  local sink
  run(function() sink=h:resolve(0,0) end)
  local rim,nextNode=h:outlet(sink)
  assert(sink.base==72 and not sink.next and rim.x==1 and rim.y==0 and nextNode.x==2 and nextNode.y==0,'Wrong lake spill/outlet')
  return sink,rim,nextNode
end
function Fixtures.region(drop,cliff,rx,ry,lake,amount,angle)
  local F,M=Regions.F,Regions.MARGIN;local ox,oy=rx*1024,ry*1024
  local upper,lower=72,72-drop
  local dx,dy=math.cos(angle or 0),math.sin(angle or 0)
  local function position(distance) return cliff+dx*distance-ox,512+dy*distance-oy end
  local region={fluid={},drops={}}
  for _,name in ipairs({'bed','water','wet','snow'}) do region[name]=ffi.new('float[?]',F*F) end
  for gy=0,F-1 do for gx=0,F-1 do
    local x,y=gx*4-M+ox,gy*4-M+oy;local i=gy*F+gx
    local u,v=(x-cliff)*dx+(y-512)*dy,-(x-cliff)*dy+(y-512)*dx
    local level=u<0 and upper or lower
    local wet=require('river_geometry').width(amount or 8)-math.abs(v)
    if lake and u<0 then wet=math.max(wet,12-math.sqrt((u+12)^2+v^2)) end
    region.bed[i]=level-1;region.water[i]=level;region.wet[i]=wet;region.snow[i]=140
  end end
  local d={ax=cliff-8-ox,ay=512-oy,mx=cliff-ox,my=512-oy,bx=cliff+16-ox,by=512-oy,
    upper=upper,lower=upper,amount=amount or 8,lake=lake}
  d.ax,d.ay=position(-8);d.mx,d.my=position(0);d.bx,d.by=position(16)
  if lake then
    local sink,rim,outlet=Fixtures.lakeOutlet()
    d.ax,d.ay=position(sink.px-rim.px);d.bx,d.by=position(outlet.px-rim.px)
  end
  local function support(x,y) return (x+ox-cliff)*dx+(y+oy-512)*dy<0 and upper-1 or lower-1 end
  d=assert(Fluid.outlet(d,support),'Production detector missed support loss')
  region.drops[1]=d
  run(function() Fluid.build(region,{SEA_LEVEL=0},rx,ry,F,M) end)
  region.hasFluid=next(region.fluid)~=nil
  return region,d
end
return Fixtures
