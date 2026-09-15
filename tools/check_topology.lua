-- Optional saved module directory compares geometry revisions without copying
-- their drainage implementation into production or into a mock.
if arg[1] then package.path=arg[1]..'/?.lua;'..package.path end
local ffi,bit,T,R=require('ffi'),require('bit'),require('terrain'),require('regions')
local function digest(bytes)
  local a,b=1,0
  for i=1,#bytes do a=(a+bytes:byte(i))%65521;b=(b+a)%65521 end
  return bit.tohex(bit.bor(bit.lshift(b,16),a))
end
local expected={
  [1337]={'d81cabea','4a744718'},[42]={'40ad8ed9','46896b9c'},[9187]={'9ec1a0ff','f817e8bd'},
  [5]={'2922b3c3','28a74f40'},[26]={'42ba52a6','baaf50b1'},[33]={'e298d279','8f25fdf9'},
}
for _,seed in ipairs({1337,42,9187,5,26,33}) do
  local t=T.new(seed);local r=t.regions;r:get(0,0)
  local n=(R.CORE+R.HALO*2+1)^2
  local graph=digest(ffi.string(r.receiver,n*4)..ffi.string(r.flow,n*2)..ffi.string(r.drainHeight,n*8))
  assert(graph==expected[seed][1],'Geometry changed pre-2.8 drainage arrays')
  print(seed,'graph',graph)
  local coast=T.new(seed,{rivers=false});local heights,surfaces=ffi.new('uint16_t[256]'),ffi.new('uint16_t[256]')
  local samples={}
  for cy=-64,64,8 do for cx=-64,64,8 do
    coast:generate(cx,cy,heights,surfaces)
    samples[#samples+1]=ffi.string(heights,512)..ffi.string(surfaces,512)
  end end
  local ocean=digest(table.concat(samples))
  assert(ocean==expected[seed][2],'Geometry changed pre-2.8 ocean/beach fields')
  print(seed,'ocean/beach',ocean)
end
print('PASS: pre-2.8 drainage and ocean/beach regression hashes')
