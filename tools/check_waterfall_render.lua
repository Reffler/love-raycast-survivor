local originalLoad=love.load
function love.load()
  originalLoad();CONFIG.DEBUG_ENABLED=false
  love.window.setMode(960,540,{fullscreen=false,vsync=0});love.resize(love.graphics.getDimensions())
  local Fixtures=require('waterfall_fixtures')
  local sloped=raycastShader
  local source=assert(love.filesystem.read('raycast.glsl')):gsub('if %(min%(camPos.z','if (false && min(camPos.z')
  local noSkip=love.graphics.newShader('#define MAX_DDA_STEPS '..MAX_DDA_STEPS..'\n'..source)
  local function shader(s)
    raycastShader=s;lastRot,lastPitch=nil,nil;updateProjection(love.graphics.getDimensions())
    s:send('heightTex',world.texture)
    if s:hasUniform('chunkMaxTex') then s:send('chunkMaxTex',world.maxTexture) end
    s:send('cacheSize',world.size);s:send('maxHeight',world.maxHeight);s:send('viewDist',CONFIG.VIEW_DIST)
  end
  local function camera(x,y,z,tx,ty,tz)
    px,py,eyeHeight=x,y,z;rot=math.atan2(ty-y,tx-x)
    pitch=math.atan2(tz-z,math.sqrt((tx-x)^2+(ty-y)^2))
    previousPx,previousPy,previousEyeHeight=px,py,eyeHeight
    eyeStepOffset,previousEyeStepOffset=0,0;physicsAccumulator=0
  end
  local function capture(name)
    shader(sloped);love.draw();local a=renderCanvas:newImageData()
    shader(noSkip);love.draw();local b=renderCanvas:newImageData()
    assert(a:getString()==b:getString(),'Waterfall changed with chunk skipping: '..name)
    local png=a:encode('png');local file=assert(io.open(os.getenv('RAYCAST_OUTPUT')..'/'..name..'.png','wb'))
    file:write(png:getString());file:close();png:release();b:release()
    local bytes=a:getString();a:release();return bytes
  end
  local function release()
    world:releaseGraphics()
  end
  local boundaryReference
  for _,c in ipairs({{'equal-level-40',40,16,false},{'lake-outlet-40',40,16,true},
      {'ramp-1',1,16,false},{'fall-20',20,16,false},
      {'small-stream-40',40,16,false,1},{'broad-river-40',40,16,false,32},{'region-boundary-40',40,1024,false}}) do
    release();world=World.new(1337,CONFIG.VIEW_DIST,{SEA_LEVEL=1,OCEAN_FLOOR=0,DETAIL_HEIGHT=0})
    local cache={}
    world.terrain.regions={get=function(_,rx,ry)
      local key=rx..','..ry
      if not cache[key] then cache[key]=Fixtures.region(c[2],c[3],rx,ry,c[4],c[5]) end
      return cache[key]
    end}
    world:initGraphics(c[3],512)
    local lower=72-c[2]
    camera(c[3]+45,542,96,c[3]-3,512,lower+c[2]*0.55)
    local bytes=capture(c[1])
    if c[1]=='equal-level-40' then boundaryReference=bytes end
    if c[1]=='region-boundary-40' then assert(bytes==boundaryReference,'Translated macro-boundary view changed pixels') end
    camera(c[3]+10,520,lower+9,c[3]+1,512,lower+0.5)
    capture(c[1]..'-landing')
    print('PASS visual fixture: '..c[1])
  end
  -- Adjacent water surfaces with an arbitrarily deep bed must have identical RGB.
  local function fill(left,right,bedLeft,bedRight)
    for _,chunk in ipairs(world.chunks) do if chunk.x~=math.huge then
      for y=0,15 do for x=0,15 do
        local i=y*16+x;local leftSide=chunk.x*16+x<1024
        chunk.data[i]=leftSide and bedLeft or bedRight
        chunk.surface[i]=(leftSide and left or right)*8
      end end
      chunk.maximum=math.max(left,right,bedLeft,bedRight);world.upload(chunk)
    end end
  end
  local function pixel()
    shader(sloped);love.draw();local data=renderCanvas:newImageData()
    local r,g,b=data:getPixel(math.floor(RENDER_W/2),math.floor(RENDER_H/2));data:release()
    return r,g,b
  end
  fill(72,72,71,1)
  camera(1016,512,85,1016,512,72);local r,g,b=pixel()
  assert(math.abs(r-0.16)<0.005 and math.abs(g-0.51)<0.005 and math.abs(b-0.57)<0.005,'Color fixture missed water')
  camera(1032,512,85,1032,512,72);local rr,gg,bb=pixel()
  assert(r==rr and g==gg and b==bb,'Deep water has a different surface color')
  camera(1045,535,94,1024,512,72);capture('shallow-deep-color')
  for _,top in ipairs({56,128}) do
    fill(top,48,1,40);camera(1032,512,52,1016,512,52)
    local fr,fg,fb=pixel()
    assert(fr==r and fg==g and fb==b,'Fall height darkens water')
    capture('fall-color-'..top)
  end
  print('PASS: deep/shallow surfaces and 8/80-block falls have identical RGB; all fixture views match unaccelerated rays')
  for _,c in ipairs({{9187,700,160,60},{1337,340,260,56}}) do
    release();world=World.new(c[1],CONFIG.VIEW_DIST);world:initGraphics(c[2],c[3])
    camera(c[2]-65,c[3]-65,c[4]+90,c[2],c[3],c[4])
    capture('curved-channel-'..c[1])
  end
  print('PASS: natural curved-channel flying views match unaccelerated rays')
end
function love.run()
  local ok,message=pcall(love.load);if not ok then print(message) end
  return function() return ok and 0 or 1 end
end
