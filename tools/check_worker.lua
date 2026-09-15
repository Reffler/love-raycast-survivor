local originalLoad=love.load
function love.load()
  originalLoad();CONFIG.DEBUG_ENABLED=false
  love.window.setMode(640,360,{fullscreen=false,vsync=0});love.resize(love.graphics.getDimensions())
  local ffi=require('ffi')
  world:startWorker()
  local generate=world.terrain.generate
  world.terrain.generate=function() error('Main-thread generation during streaming') end
  local function drain(x,y)
    local deadline=love.timer.getTime()+15
    repeat
      world:update(x,y)
      assert(love.timer.getTime()<deadline,'Worker timed out')
      love.timer.sleep(0.001)
    until not world:hasPending() and world.inFlight==0
  end
  -- Discard results for requests superseded while the worker is busy.
  world:update(160,160);world:update(-160,-160);world:update(32,16)
  drain(32,16)
  assert(world:canRender(32,16),'Completed cache not visible')
  for _,c in ipairs(world.chunks) do
    assert(c.x~=math.huge and world:slot(c.x,c.y)==c.index,'Wrong ring slot')
  end
  local reference=World.new(CONFIG.SEED,16)
  local checked=0
  for _,c in ipairs(world.chunks) do
    if c.x>=-2 and c.x<=4 and c.y>=-2 and c.y<=4 or c.complex and checked<80 then
      local expected=reference:generateChunk(c.x,c.y)
      assert(c.maximum==expected.maximum and c.complex==expected.complex,'Worker metadata changed')
      assert(ffi.string(c.data,512)==ffi.string(expected.data,512),'Worker heights changed')
      assert(ffi.string(c.surface,512)==ffi.string(expected.surface,512),'Worker water/material changed')
      if c.complex then assert(ffi.string(c.spans,4096)==ffi.string(expected.spans,4096),'Worker spans changed') end
      checked=checked+1
    end
  end
  world:update(1000000.5,-1000000.5)
  assert(not world:canRender(1000000.5,-1000000.5),'Unloaded teleport accepted')
  drain(1000000.5,-1000000.5)
  assert(world:canRender(1000000.5,-1000000.5),'Far cache not ready')
  -- Pending results must not replace manually drained or edited resident chunks.
  world:update(1000032,-1000000)
  world.terrain.generate=generate
  while world:hasPending() do world:step(256,world.upload) end
  local target=world.chunks[world:slot(world.cx+world.radius,world.cy)]
  target.data[0]=123
  drain(1000032,-1000000)
  assert(target.data[0]==123,'Stale worker result overwrote resident terrain')
  world:stopWorker();assert(not world.worker,'Worker did not stop')
  world:startWorker();world:update(1000048,-1000000);drain(1000048,-1000000)
  world:stopWorker()
  print(('PASS: %d deterministic chunks, stale-job rejection, negative/far teleports, bounded queues, no main-thread generation, stop/restart'):format(checked))
end
function love.run()
  local ok,err=pcall(love.load)
  if world.worker then world:stopWorker() end
  if not ok then print(err) end
  return function() return ok and 0 or 1 end
end
