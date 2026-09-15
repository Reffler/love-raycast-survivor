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
  return math.max(0,1-(math.sqrt(second)-math.sqrt(first))*field.width),math.sqrt(second)-math.sqrt(first)
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
    local ridge,distance=G.ridge(config,x,y)
    local mountainType=G.noise(wx/1408,wy/1408,seed+2309)
    local plateauStrength=G.smooth((G.noise(wx/896,wy/896,seed+2399)-0.32)/0.48)*(1-0.25*mountainType)
    local shoulder=G.noise(wx/256,wy/256,seed+2459)
    local amplitude=110+58*G.noise(x/768,y/768,seed+887)
    -- Range distance places uplift; three independent widths shape its cross-section.
    local width=0.48+0.30*mountainType
    local broadMassif=G.smooth(1-distance/width)
    local ridgeShoulder=G.smooth(1-distance/(0.24+0.18*shoulder))
    local sharpness=2+5*mountainType
    local sharpCrest=ridge^sharpness
    -- Compress relative height with a smooth knee, never a fixed world-height terrace.
    local threshold=0.46+0.20*shoulder
    local upper=math.max(0,broadMassif-threshold)
    broadMassif=broadMassif-plateauStrength*0.85*upper*upper/(upper+0.09)
    -- Broad benches and localized steep faces vary continuously along the network.
    local bench=G.smooth((ridgeShoulder-(0.25+0.16*variation))/0.35)
    ridgeShoulder=ridgeShoulder*(1-0.45*plateauStrength)+bench*0.45*plateauStrength
    local cliffStrength=G.smooth((mountainType-0.45)/0.4)*(1-plateauStrength)
    broadMassif=broadMassif*(1-cliffStrength*0.35)+G.smooth((broadMassif-0.15)/0.65)*cliffStrength*0.35
    local crestWeight=0.08+0.20*G.smooth((mountainType-0.55)/0.3)
    local mountain=0.50*broadMassif+0.30*ridgeShoulder*(0.7+0.4*shoulder+0.2*(1-mountainType))+crestWeight*sharpCrest
    base=base+land*mask*(amplitude*mountain+6*(variation-0.5)*broadMassif)
    -- Some mountain ranges meet the sea abruptly; others have wide lowlands.
    local cliff=G.smooth((G.noise(x/512,y/512,seed+1103)-0.48)/0.22)*mask
    base=base+36*cliff*G.smooth((c-0.445)/0.03)*(1-G.smooth((c-0.51)/0.1))
  end
  return math.max(1,math.min(238,base)),130+25*G.noise(x/1024,y/1024,seed+1601)
end
-- Called only on cached 32-block controls, never in chunk column loops.
function G.material(config,x,y,climate,curvature)
  local seed=config.seed
  local wx=x+100*(G.noise(x/384,y/384,seed+2609)-0.5)
  local wy=y+100*(G.noise(x/384,y/384,seed+2671)-0.5)
  local geology=G.noise(wx/224,wy/224,seed+2707)-0.5
  local elevation=G.noise(wx/480,wy/480,seed+2791)-0.5
  local patch=G.noise(wx/64,wy/64,seed+2801)-0.5
  local exposure=math.max(-1,math.min(1,curvature/12))
  return climate+42*elevation+16*patch+7*exposure,
    0.85+0.55*geology+0.30*patch-0.24*exposure
end
return G
