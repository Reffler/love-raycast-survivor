local originalLoad=love.load
function love.load()
  originalLoad();CONFIG.DEBUG_ENABLED=false
  love.window.setMode(1920,1080,{fullscreen=false,vsync=0});love.resize(love.graphics.getDimensions())
  if world.startWorker then world:startWorker() end
  local fps,seconds=tonumber(os.getenv('STREAM_FPS')),tonumber(os.getenv('STREAM_SECONDS'))
  local file=assert(io.open(os.getenv('STREAM_OUTPUT')..'/frames.csv','w'))
  file:write('frame,work_ms,stream_ms,interval_ms,pending,inflight,ready\n')
  local frames,streams,intervals={},{},{}
  local misses,blocked=0,0
  local clock=love.timer.getTime();local deadline=clock
  for i=1,fps*seconds do
    local start=love.timer.getTime();intervals[i]=(start-clock)*1000;clock=start
    px,py=3.5+i*40/fps,3.5+i*30/fps
    local t=love.timer.getTime();world:update(px,py);streams[i]=(love.timer.getTime()-t)*1000
    local ready=not world.canRender or world:canRender(px,py)
    if not ready then blocked=blocked+1 end
    eyeHeight=world:height(math.floor(px),math.floor(py))+30
    previousPx,previousPy,previousEyeHeight=px,py,eyeHeight
    eyeStepOffset,previousEyeStepOffset,physicsAccumulator=0,0,0
    rot,pitch=math.atan2(30,40),math.rad(-15)
    if ready then love.draw();renderCanvas:newImageData():release() end
    frames[i]=(love.timer.getTime()-start)*1000
    if frames[i]>1000/fps then misses=misses+1 end
    file:write(('%d,%.6f,%.6f,%.6f,%d,%d,%s\n'):format(i,frames[i],streams[i],intervals[i],world.pendingCount,world.inFlight or 0,tostring(ready)))
    deadline=deadline+1/fps
    local remaining=deadline-love.timer.getTime()
    if remaining>0 then love.timer.sleep(remaining) else deadline=love.timer.getTime() end
  end
  file:close()
  local function report(name,values)
    table.sort(values);local n=#values
    print(('%s median=%.3f p95=%.3f p99=%.3f p99.9=%.3f max=%.3f ms'):format(name,values[math.ceil(n*.5)],values[math.ceil(n*.95)],values[math.ceil(n*.99)],values[math.ceil(n*.999)],values[n]))
  end
  print('Renderer: '..table.concat({love.graphics.getRendererInfo()},' | '))
  print(('1080p, 556 blocks, 50 blocks/s, %d FPS schedule, %d frames; deadline misses=%d; unavailable views=%d'):format(fps,#frames,misses,blocked))
  report('frame work + readback',frames);report('streaming',streams);report('frame intervals',intervals)
  if world.stopWorker then world:stopWorker() end
  assert(blocked==0,'Worker failed to preload visible terrain')
end
function love.run()
  local ok,err=pcall(love.load)
  if world.stopWorker then world:stopWorker() end
  if not ok then print(err) end
  return function() return ok and 0 or 1 end
end
