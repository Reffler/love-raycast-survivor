local originalLoad=love.load
function love.load()
  CONFIG.AA_ENABLED=false -- Exact frame comparisons test geometry independently of temporal history.
  originalLoad();CONFIG.DEBUG_ENABLED=false
  love.window.setMode(640,360,{fullscreen=false,vsync=0});love.resize(love.graphics.getDimensions())
  flying=true;eyeHeight=world.maxHeight+10;previousEyeHeight=eyeHeight
  rot,pitch=math.atan2(30,40),math.rad(-20)
  love.keyboard.isDown=function(...)
    for i=1,select('#',...) do local key=select(i,...);if key=='w' or key=='lshift' then return true end end
    return false
  end
  local function forbidden() error('Main-thread terrain generation during movement') end
  local generate=world.terrain.generate
  world.terrain.generate,world.terrain.height,world.terrain.spansAt=forbidden,forbidden,forbidden
  local deadline=love.timer.getTime()
  for i=1,720 do
    love.update(1/60)
    assert(world:canRender(px,py),'Player entered unloaded cache')
    assert(world.inFlight<=32,'Worker queue unbounded')
    love.draw()
    deadline=deadline+1/60
    local wait=deadline-love.timer.getTime();if wait>0 then love.timer.sleep(wait) end
  end
  local distance=math.sqrt((px-3.5)^2+(py-3.5)^2)
  assert(distance>599 and distance<=600,'Streaming slowed sprint: '..distance)
  love.draw();local before=renderCanvas:newImageData();local expected=before:getString();before:release()
  world:stopWorker();world.terrain.generate=generate
  while world:hasPending() do world:step(256,world.upload) end
  -- Reupload resident CPU buffers; framebuffer must already contain those exact data.
  for _,c in ipairs(world.chunks) do world.upload(c) end
  love.draw();local after=renderCanvas:newImageData()
  assert(after:getString()==expected,'Worker GPU uploads differ from resident CPU data');after:release()
  print(('PASS: production update/physics, %.3f blocks in 12 seconds, no main-thread terrain calls, bounded queue, exact GPU uploads'):format(distance))
end
function love.run()
  local ok,err=pcall(love.load);world:stopWorker()
  if not ok then print(err) end
  return function() return ok and 0 or 1 end
end
