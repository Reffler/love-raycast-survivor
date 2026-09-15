-- Deterministic aerial survey of 4096x4096 blocks; saves flat-color hillshade maps.
local ffi,Terrain=require('ffi'),require('terrain')
local seed=tonumber(arg[1]);local output=assert(arg[2]);local detail=tonumber(arg[3]) or 1.25
local t=Terrain.new(seed,{DETAIL_HEIGHT=detail})
local width=512;local pixels=ffi.new('uint8_t[?]',width*width*3)
local palette={{0.32,0.62,0.18},{0.76,0.69,0.43},{0.43,0.46,0.48},{0.9,0.94,0.96},{0.43,0.28,0.15}}
local counts={0,0,0,0,0};local ocean,rivers=0,0
local peak,coast,river,plain=nil,nil,nil,nil
local highest=-1
local bestRiver,bestCoast,bestPlain=-math.huge,-math.huge,-math.huge
for py=0,width-1 do for px=0,width-1 do
  local x,y=(px-width/2)*8,(py-width/2)*8
  local height,code=t:height(x,y);local mat,water=math.floor(code/2048),(code%2048)/8
  counts[mat+1]=counts[mat+1]+1
  local color=palette[mat+1]
  local r,g,b=color[1],color[2],color[3]
  local region=t.regions:find(math.floor(x/1024),math.floor(y/1024))
  local R=require("regions");local k=((y%1024)+R.MARGIN)/4*R.F+((x%1024)+R.MARGIN)/4
  local slope=(region.bed[k]-region.bed[k+1])*0.12+(region.bed[k]-region.bed[k+R.F])*0.08
  local light=math.max(0.42,math.min(1.15,0.88+slope))
  if water>height then
    local deep=math.min(1,(water-height)/14)
    r,g,b=0.16+(0.08-0.16)*deep,0.51+(0.27-0.51)*deep,0.57+(0.48-0.57)*deep;light=1
    if water>t.settings.SEA_LEVEL then rivers=rivers+1;local score=-math.abs(water-68)-0.001*(math.abs(x)+math.abs(y));if score>bestRiver then bestRiver=score;river={x,y,water} end else ocean=ocean+1 end
  elseif height>highest then highest=height;peak={x,y,height} end
  if mat==1 and water==0 and height>=t.settings.SEA_LEVEL and height<=t.settings.SEA_LEVEL+3 then local score=-math.abs(x)-math.abs(y);if score>bestCoast then bestCoast=score;coast={x,y,height} end end
  if mat==0 and height>t.settings.SEA_LEVEL and height<t.settings.SEA_LEVEL+14 and water==0 then local score=-math.abs(x)-math.abs(y);if score>bestPlain then bestPlain=score;plain={x,y,height} end end
  local i=(py*width+px)*3
  pixels[i]=math.min(255,r*light*255);pixels[i+1]=math.min(255,g*light*255);pixels[i+2]=math.min(255,b*light*255)
end end
local file=assert(io.open(output,'wb'));file:write(('P6\n%d %d\n255\n'):format(width,width),ffi.string(pixels,width*width*3));file:close()
local function point(name,value) if value then print(('POINT,%s,%d,%d,%d'):format(name,unpack(value))) end end
point('peak',peak);point('coast',coast);point('river',river);point('plain',plain)
print(('COUNTS,grass=%d,sand=%d,rock=%d,snow=%d,dirt=%d,ocean=%d,river=%d'):format(counts[1],counts[2],counts[3],counts[4],counts[5],ocean,rivers))
