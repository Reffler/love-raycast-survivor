-- Own Lua state and terrain cache; Channels own completed buffers until consumed.
require('love.data')
local ffi,Terrain=require('ffi'),require('terrain')
local jobs,results,seed,settings=...
local terrain=Terrain.new(seed,settings)
local heights,surface,spans=ffi.new('uint16_t[256]'),ffi.new('uint16_t[256]'),ffi.new('int16_t[2048]')
while true do
  local job=jobs:demand()
  if job==false then break end
  local ticket,cx,cy,forceSpans=unpack(job)
  local before=terrain.spanOverflowCount
  local maximum,complex=terrain:generate(cx,cy,heights,surface,spans)
  if forceSpans then
    complex=true;ffi.fill(spans,4096,255)
    for i=0,255 do spans[i*8]=0;spans[i*8+1]=heights[i] end
  end
  local bytes=love.data.newByteData(complex and 5120 or 1024)
  local data=ffi.cast('uint8_t*',bytes:getFFIPointer())
  ffi.copy(data,heights,512);ffi.copy(data+512,surface,512)
  if complex then ffi.copy(data+1024,spans,4096) end
  results:push({ticket,cx,cy,maximum,complex,terrain.spanOverflowCount-before,bytes})
end
