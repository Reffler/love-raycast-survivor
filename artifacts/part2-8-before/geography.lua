local bit=require('bit')
local G={}
function G.hash(x,y,seed)
  local n=(x*374761393+y*668265263+seed*1447)%2147483647
  n=bit.bxor(n,bit.rshift(n,13));n=(n*16807)%2147483647
  n=bit.bxor(n,bit.rshift(n,11));n=(n*16807)%2147483647
  return n/2147483647
end
function G.smooth(t) t=math.max(0,math.min(1,t));return t*t*(3-2*t) end
function G.noise(x,y,seed)
  local ix,iy=math.floor(x),math.floor(y);local u,v=G.smooth(x-ix),G.smooth(y-iy)
  local a,b,c,d=G.hash(ix,iy,seed),G.hash(ix+1,iy,seed),G.hash(ix,iy+1,seed),G.hash(ix+1,iy+1,seed)
  return (a+(b-a)*u)*(1-v)+(c+(d-c)*u)*v
end
-- Warped Voronoi edges form a connected ridge network; masks select mountain chains.
function G.ridge(config,x,y)
  local seed,field=config.seed,config.ridgeField
  local wx=x+field.warp*(G.noise(x/field.warpScale,y/field.warpScale,seed+211)-0.5)
  local wy=y+field.warp*(G.noise(x/field.warpScale,y/field.warpScale,seed+307)-0.5)
  wx,wy=wx/field.spacingX,wy/field.spacingY
  local ix,iy=math.floor(wx),math.floor(wy);local first,second=1e9,1e9
  for dy=-1,1 do for dx=-1,1 do
    local px,py=ix+dx,iy+dy
    local xx=px+0.15+0.7*G.hash(px,py,seed+field.salt)-wx
    local yy=py+0.15+0.7*G.hash(px,py,seed+field.salt+102)-wy
    local d=xx*xx+yy*yy
    if d<first then second=first;first=d elseif d<second then second=d end
  end end
  return math.max(0,1-(math.sqrt(second)-math.sqrt(first))*field.width)
end
function G.height(config,x,y)
  local seed,sea=config.seed,config.SEA_LEVEL
  local wx=x+500*(G.noise(x/1536,y/1536,seed+31)-0.5)
  local wy=y+500*(G.noise(x/1536,y/1536,seed+53)-0.5)
  local c=G.noise(wx/config.CONTINENT_SCALE,wy/config.CONTINENT_SCALE,seed)
  c=c+0.1*(G.noise(x/512,y/512,seed+97)-0.5)
  local base
  if c<0.35 then base=config.OCEAN_FLOOR+(sea-12-config.OCEAN_FLOOR)*G.smooth(c/0.35)
  elseif c<0.46 then base=sea-12+12*G.smooth((c-0.35)/0.11)
  elseif c<0.58 then base=sea+10*G.smooth((c-0.46)/0.12)
  else base=sea+10+10*G.smooth((c-0.58)/0.3) end
  local variationField=config.terrainVariation
  local variation=G.noise(x/variationField.spacingX,y/variationField.spacingY,seed+variationField.salt)
  local land=G.smooth((c-0.43)/0.09)
  base=base+(variation-0.5)*4*land
  if config.mountains then
    local field=config.mountainMask
    local mask=G.smooth((G.noise(x/field.spacingX,y/field.spacingY,seed+field.salt)-field.start)/field.range)
    local ridge=G.ridge(config,x,y)
    local amplitude=92+62*G.noise(x/768,y/768,seed+887)
    -- Broad foothills, eroded lower slopes, narrow peaks and occasional hard faces.
    local eroded=ridge*ridge*(0.65+0.35*variation)
    base=base+land*mask*amplitude*(0.12*ridge+0.88*eroded)
    -- Some mountain ranges meet the sea abruptly; others have wide lowlands.
    local cliff=G.smooth((G.noise(x/512,y/512,seed+1103)-0.48)/0.22)*mask
    base=base+36*cliff*G.smooth((c-0.445)/0.03)*(1-G.smooth((c-0.51)/0.1))
  end
  return math.max(1,math.min(238,base)),130+25*G.noise(x/1024,y/1024,seed+1601)
end
return G
