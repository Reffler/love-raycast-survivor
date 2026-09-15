-- Independent coarse fields. Ridge contours can span many chunks; no biomes/caves.
local ffi,bit=require('ffi'),require('bit')
local Terrain={}
Terrain.__index=Terrain
Terrain.defaults={
  continentalness={spacingX=512,spacingY=512,salt=0},
  mountainMask={spacingX=256,spacingY=256,salt=173},
  ridgeField={spacingX=128,spacingY=32,salt=419},
  terrainVariation={spacingX=32,spacingY=32,salt=683},
  detail={spacingX=8,spacingY=8,salt=1013},
  baseHeight=8,continentHeight=20,mountainHeight=48,rollingHeight=6,detailHeight=2,
  mountainStart=0.45,mountainFull=0.8,
}
local names={'continentalness','mountainMask','ridgeField','terrainVariation','detail'}
local function hash(x,y,seed)
  local n=(x*374761393+y*668265263+seed*1447)%2147483647
  n=bit.bxor(n,bit.rshift(n,13));n=(n*16807)%2147483647
  n=bit.bxor(n,bit.rshift(n,11));n=(n*16807)%2147483647
  return n/2147483647
end
local function smooth(t) return t*t*(3-2*t) end
local function interpolate(a,b,c,d,u,v) return (a+(b-a)*u)*(1-v)+(c+(d-c)*u)*v end
function Terrain.new(seed,config)
  config=config or Terrain.defaults
  local self=setmetatable({fields={},controls=ffi.new('double[25]'),weights=ffi.new('double[16]'),
    columns=ffi.new('int[16]'),values=ffi.new('double[1280]')},Terrain)
  for i,name in ipairs(names) do
    local def=config[name] or Terrain.defaults[name]
    local sx,sy=def.spacingX,def.spacingY
    assert(sx>=4 and sy>=4 and sx==math.floor(sx) and sy==math.floor(sy),'Field spacing must be integer >= 4')
    self.fields[i]={spacingX=sx,spacingY=sy,seed=seed+def.salt}
  end
  for _,name in ipairs({'baseHeight','continentHeight','mountainHeight','rollingHeight','detailHeight','mountainStart','mountainFull'}) do
    self[name]=config[name] or Terrain.defaults[name]
  end
  assert(self.mountainFull>self.mountainStart,'Mountain mask range must be positive')
  self.maskScale=1/(self.mountainFull-self.mountainStart)
  assert(self.baseHeight>=0 and self.continentHeight>=0 and self.mountainHeight>=0 and self.rollingHeight>=0 and self.detailHeight>=0,'Height amplitudes must be nonnegative')
  self.maxHeight=math.ceil(self.baseHeight+self.continentHeight+self.mountainHeight+(self.rollingHeight+self.detailHeight)*0.5)
  assert(self.maxHeight<=2048,'Integer heights above 2048 cannot be represented exactly by r16f')
  return self
end
function Terrain:compose(continent,mountain,ridge,variation,detail)
  local mask=smooth(math.max(0,math.min(1,(mountain-self.mountainStart)*self.maskScale)))
  -- Ridged signed field: connected contours, independently masked into mountain regions.
  ridge=1-math.abs(2*ridge-1)
  return math.max(0,math.floor(self.baseHeight+continent*self.continentHeight+
    mask*ridge*ridge*self.mountainHeight+(variation-0.5)*self.rollingHeight+(detail-0.5)*self.detailHeight))
end
local function sample(field,x,y)
  local fx,fy=x/field.spacingX,y/field.spacingY
  local ix,iy=math.floor(fx),math.floor(fy)
  return interpolate(hash(ix,iy,field.seed),hash(ix+1,iy,field.seed),
    hash(ix,iy+1,field.seed),hash(ix+1,iy+1,field.seed),smooth(fx-ix),smooth(fy-iy))
end
function Terrain:height(x,y)
  local fields=self.fields
  return self:compose(sample(fields[1],x,y),sample(fields[2],x,y),sample(fields[3],x,y),
    sample(fields[4],x,y),sample(fields[5],x,y))
end
function Terrain:generate(cx,cy,output)
  local x,y=cx*16,cy*16
  local controls,weights,columns,values=self.controls,self.weights,self.columns,self.values
  for layer=1,5 do
    local field=self.fields[layer]
    local sx,sy=field.spacingX,field.spacingY
    local bx,by=math.floor(x/sx),math.floor(y/sy)
    local nx,ny=math.floor((x+15)/sx)-bx+2,math.floor((y+15)/sy)-by+2
    -- Each lattice value is hashed once per field/chunk, never in the block loop.
    for j=0,ny-1 do for i=0,nx-1 do controls[j*nx+i]=hash(bx+i,by+j,field.seed) end end
    for i=0,15 do
      local fx=(x+i)/sx;local ix=math.floor(fx)
      columns[i]=ix-bx;weights[i]=smooth(fx-ix)
    end
    local offset=(layer-1)*256
    for j=0,15 do
      local fy=(y+j)/sy;local iy=math.floor(fy);local v=smooth(fy-iy)
      local row=(iy-by)*nx
      for i=0,15 do
        local k=row+columns[i]
        values[offset+j*16+i]=interpolate(controls[k],controls[k+1],controls[k+nx],controls[k+nx+1],weights[i],v)
      end
    end
  end
  local maximum=0
  for i=0,255 do
    local h=self:compose(values[i],values[256+i],values[512+i],values[768+i],values[1024+i])
    output[i]=h;maximum=math.max(maximum,h)
  end
  return maximum
end
return Terrain
