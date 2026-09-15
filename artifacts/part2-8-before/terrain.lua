local ffi,G,Regions=require('ffi'),require('geography'),require('regions')
local Fluid=require('fluid')
local F,M=Regions.F,Regions.MARGIN
local Terrain={BANK_GUARD=2}
Terrain.__index=Terrain
Terrain.defaults={SEA_LEVEL=48,OCEAN_FLOOR=8,CONTINENT_SCALE=2048,DETAIL_HEIGHT=1.25,
  mountains=true,rivers=true,materials=true,
  mountainMask={spacingX=1024,spacingY=1024,salt=173,start=0.38,range=0.32},
  ridgeField={spacingX=640,spacingY=384,salt=419,warp=300,warpScale=512,width=3.8},
  terrainVariation={spacingX=160,spacingY=160,salt=683}}
function Terrain.new(seed,config)
  config=config or {}
  local settings={seed=seed}
  for k,v in pairs(Terrain.defaults) do
    if type(v)=='table' then
      local field={};for name,value in pairs(v) do field[name]=config[k] and config[k][name] or value end
      settings[k]=field
    elseif config[k]~=nil then settings[k]=config[k] else settings[k]=v end
  end
  if config.detailHeight then settings.DETAIL_HEIGHT=config.detailHeight end
  if config.stage=='geography' then settings.mountains=false;settings.rivers=false;settings.materials=false
  elseif config.stage=='mountains' then settings.rivers=false;settings.materials=false
  elseif config.stage=='rivers' then settings.materials=false end
  assert(settings.SEA_LEVEL>settings.OCEAN_FLOOR and settings.SEA_LEVEL<128,'Sea level must be above ocean floor and below 128')
  assert(settings.SEA_LEVEL==math.floor(settings.SEA_LEVEL) and settings.OCEAN_FLOOR==math.floor(settings.OCEAN_FLOOR),'Sea/floor heights must be integers')
  assert(settings.OCEAN_FLOOR>=0 and settings.CONTINENT_SCALE>=512 and settings.CONTINENT_SCALE<math.huge,'Invalid geography scale/floor')
  assert(settings.DETAIL_HEIGHT>=0 and settings.DETAIL_HEIGHT<=8,'Detail amplitude must be 0..8')
  for _,name in ipairs({'mountainMask','ridgeField','terrainVariation'}) do
    local f=settings[name];assert(f.spacingX>=32 and f.spacingY>=32 and f.spacingX<math.huge and f.spacingY<math.huge,'Macro spacing must be finite and >=32')
  end
  assert(settings.mountainMask.range>0 and settings.ridgeField.width>0 and settings.ridgeField.warpScale>=32,'Invalid mountain fields')
  local self=setmetatable({settings=settings,maxHeight=254,regions=Regions.new(settings),controls=ffi.new('double[9]'),weights=ffi.new('double[16]'),values=ffi.new('double[1536]')},Terrain)
  return self
end
function Terrain:ready(cx,cy) return self.regions:request(math.floor(cx/64),math.floor(cy/64))~=nil end
function Terrain:advance(seconds) self.regions:advance(seconds) end
local function mix(a,b,t) return a+(b-a)*t end
function Terrain:column(region,x,y,detail)
  local fx,fy=(x+M)/4,(y+M)/4;local ix,iy=math.floor(fx),math.floor(fy);local u,v=fx-ix,fy-iy
  local k=iy*F+ix;local bed=region.bed
  local a,b,c,d=bed[k],bed[k+1],bed[k+F],bed[k+(F+1)]
  local h=mix(mix(a,c,v),mix(b,d,v),u)
  local slope=math.max(math.abs(mix(b-a,d-c,v)),math.abs(mix(c-a,d-b,u)))/4
  local water,wet,snow=region.water,region.wet,region.snow
  local wetness=mix(mix(wet[k],wet[k+F],v),mix(wet[k+1],wet[k+(F+1)],v),u)
  -- Water is categorical: interpolation would invent disconnected terraces.
  local level=water[(iy+(v>=0.5 and 1 or 0))*F+ix+(u>=0.5 and 1 or 0)]
  local snowLine=mix(mix(snow[k],snow[k+F],v),mix(snow[k+1],snow[k+(F+1)],v),u)
  return self:finish(h,slope,level,wetness,snowLine,detail,region.hasFluid and region.fluid[Fluid.key(x,y)])
end
function Terrain:finish(h,slope,level,wetness,snowLine,detail,fluid)
  local sea=self.settings.SEA_LEVEL
  if wetness<0 then h=h+(detail-0.5)*self.settings.DETAIL_HEIGHT*G.smooth((h-sea)/6) end
  -- Bed interpolation across a drop must not dam the lower reach.
  if level>sea then
    if wetness>0 then h=math.min(h,level-1)
    elseif wetness>-Terrain.BANK_GUARD then h=math.max(h,level) end
  elseif wetness>0 and level>0 then h=math.min(h,level-1) end
  if fluid then h=math.max(fluid.bank or 0,math.min(h,fluid.bed or 254)) end
  h=math.max(0,math.min(254,math.floor(h)))
  local waterHeight=wetness>0 and level>0 and math.floor(level) or h<sea and sea or 0
  if fluid and fluid.top then waterHeight=fluid.top end
  if waterHeight<=h then waterHeight=0 end
  local material=0
  if self.settings.materials then
    if h>=snowLine and slope<1.7 then material=3
    elseif slope>0.85 then material=2
    elseif h<=sea+2+(snowLine-130)*0.2 and h>=sea-9 and slope<0.42 then material=1
    elseif h<sea-9 then material=4 end
  end
  return h,material*2048+waterHeight*8,waterHeight
end
function Terrain:height(x,y)
  local rx,ry=math.floor(x/1024),math.floor(y/1024)
  local r=self.regions:get(rx,ry)
  return self:column(r,x-rx*1024,y-ry*1024,G.noise(x/8,y/8,self.settings.seed+1013))
end
function Terrain:generate(cx,cy,output,surface)
  local x,y=cx*16,cy*16;local rx,ry=math.floor(x/1024),math.floor(y/1024)
  local region=self.regions:get(rx,ry);local values=self.values
  local fluids=region.fluidChunks[(cy%64)*64+cx%64]
  local ox,oy=(x%1024+M)/4,(y%1024+M)/4
  -- Separate interpolation passes keep LuaJIT register pressure bounded.
  for layer=0,3 do
    local source=layer==0 and region.bed or layer==1 and region.water or layer==2 and region.wet or region.snow
    for j=0,15 do
      local row=(oy+math.floor(j/4))*F+ox;local v=(j%4)/4
      for block=0,3 do
        local k=row+block
        local a=mix(source[k],source[k+F],v)
        local d=(mix(source[k+1],source[k+(F+1)],v)-a)/4
        local o=layer*256+j*16+block*4
        if layer==1 then
          local w=k+(v>=0.5 and F or 0)
          values[o]=source[w];values[o+1]=source[w];values[o+2]=source[w+1];values[o+3]=source[w+1]
        else values[o]=a;values[o+1]=a+d;values[o+2]=a+d*2;values[o+3]=a+d*3 end
      end
    end
  end
  local bed=region.bed
  for j=0,15 do for i=0,15 do
    local xx,yy=ox+i/4,oy+j/4;local k=math.floor(yy)*F+math.floor(xx)
    local u,v=xx-math.floor(xx),yy-math.floor(yy)
    values[1024+j*16+i]=math.max(math.abs(mix(bed[k+1]-bed[k],bed[k+(F+1)]-bed[k+F],v)),math.abs(mix(bed[k+F]-bed[k],bed[k+(F+1)]-bed[k+1],u)))/4
  end end
  local controls,weights=self.controls,self.weights
  for j=0,2 do for i=0,2 do controls[j*3+i]=G.hash(x/8+i,y/8+j,self.settings.seed+1013) end end
  for i=0,15 do weights[i]=G.smooth((i%8)/8) end
  for j=0,15 do for i=0,15 do
    local k=math.floor(j/8)*3+math.floor(i/8)
    values[1280+j*16+i]=mix(mix(controls[k],controls[k+1],weights[i]),mix(controls[k+3],controls[k+4],weights[i]),weights[j])
  end end
  local maximum=0
  for i=0,255 do
    local h,code,water=self:finish(values[i],values[1024+i],values[256+i],values[512+i],values[768+i],values[1280+i],fluids and fluids[i])
    output[i]=h;if surface then surface[i]=code end
    maximum=math.max(maximum,h,math.ceil(water))
  end
  return maximum
end
return Terrain
