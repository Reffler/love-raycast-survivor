-- Macro-only geometry. Shared by support detection, carving and sparse fluid.
local G=require('geography')
local C={}
function C.width(amount) return 3+math.sqrt(amount)*1.3 end
local function unit(x,y)
  local length=math.sqrt(x*x+y*y)
  if length<1e-9 then return 1,0 end
  return x/length,y/length
end
function C.curve(d,seed,ox,oy)
  if d.points then return d end
  local points={};d.points=points
  d.minx,d.maxx,d.miny,d.maxy=d.ax,d.ax,d.ay,d.ay
  local function append(x,y)
    -- Binary sub-block coordinates make translated segment differences exact.
    x,y=math.floor(x*65536+0.5)/65536,math.floor(y*65536+0.5)/65536
    local previous=points[#points]
    local s=previous and previous.s+math.sqrt((x-previous.x)^2+(y-previous.y)^2) or 0
    points[#points+1]={x=x,y=y,s=s}
    d.minx,d.maxx=math.min(d.minx,x),math.max(d.maxx,x)
    d.miny,d.maxy=math.min(d.miny,y),math.max(d.maxy,y)
  end
  local function segment(ax,ay,bx,by,tx,ty,ux,uy,first)
    local dx,dy=bx-ax,by-ay;local length=math.sqrt(dx*dx+dy*dy)
    local count=math.max(2,math.ceil(length/2.5))
    for i=first and 0 or 1,count do
      local t=i/count;local t2,t3=t*t,t*t*t
      local x=ax+(-2*t3+3*t2)*dx+(t3-2*t2+t)*length*tx+(t3-t2)*length*ux
      local y=ay+(-2*t3+3*t2)*dy+(t3-2*t2+t)*length*ty+(t3-t2)*length*uy
      if seed then
        -- Position and first derivative vanish at endpoints: no join kinks.
        local bend=(G.noise((x+ox)/64,(y+oy)/64,seed+2293)-0.5)*math.min(6,length*0.16)*16*t2*(1-t)^2
        x,y=x-dy/math.max(1,length)*bend,y+dx/math.max(1,length)*bend
      end
      append(x,y)
    end
  end
  local tx,ty=unit(d.bx-d.ax,d.by-d.ay)
  if d.lake then
    local ax,ay=unit(d.mx-d.ax,d.my-d.ay)
    local bx,by=unit(d.bx-d.mx,d.by-d.my)
    local mx,my=unit(ax+bx,ay+by)
    segment(d.ax,d.ay,d.mx,d.my,ax,ay,mx,my,true)
    segment(d.mx,d.my,d.bx,d.by,mx,my,bx,by,false)
  else segment(d.ax,d.ay,d.bx,d.by,d.tx or tx,d.ty or ty,d.ux or tx,d.uy or ty,true) end
  d.length=points[#points].s
  return d
end
function C.at(d,t)
  C.curve(d)
  local p=d.points;local s=math.max(0,math.min(1,t))*d.length
  for i=2,#p do if p[i].s>=s then
    local a,b=p[i-1],p[i];local span=math.max(1e-9,b.s-a.s);local u=(s-a.s)/span
    return a.x+(b.x-a.x)*u,a.y+(b.y-a.y)*u,(b.x-a.x)/span,(b.y-a.y)/span
  end end
  local a,b=p[#p-1],p[#p];local span=math.max(1e-9,b.s-a.s)
  return b.x,b.y,(b.x-a.x)/span,(b.y-a.y)/span
end
function C.distance(d,x,y)
  local points=d.points;local best,s=math.huge,0
  for i=2,#points do
    local a,b=points[i-1],points[i];local dx,dy=b.x-a.x,b.y-a.y
    local u=math.max(0,math.min(1,((x-a.x)*dx+(y-a.y)*dy)/math.max(1e-9,dx*dx+dy*dy)))
    local distance=(x-a.x-dx*u)^2+(y-a.y-dy*u)^2
    if distance<best then best,s=distance,a.s+(b.s-a.s)*u end
  end
  return math.sqrt(best),s/math.max(1e-9,d.length)
end
function C.lake(lake,seed,ox,oy)
  lake.seed,lake.ox,lake.oy=seed,ox,oy
  local angle=G.hash(math.floor(lake.x+ox),math.floor(lake.y+oy),seed+2371)*math.pi*2
  lake.cos,lake.sin=math.cos(angle),math.sin(angle)
  return lake
end
function C.lakeDistance(lake,x,y)
  local dx,dy=x-lake.x,y-lake.y
  if not lake.seed then return math.sqrt(dx*dx+dy*dy) end
  local u,v=dx*lake.cos+dy*lake.sin,dy*lake.cos-dx*lake.sin
  local warp=(G.noise((x+lake.ox)/24,(y+lake.oy)/24,lake.seed+2399)-0.5)*lake.width*0.5
  return math.sqrt(u*u/1.44+v*v*1.44)-warp
end
return C
