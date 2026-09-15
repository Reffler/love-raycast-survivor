-- Appended to main.lua. Timings include GPU synchronization/readback, exclude presentation.
local originalLoad=love.load
function love.load()
  originalLoad()
  love.window.setMode(1920,1080,{fullscreen=false,vsync=0});love.resize(love.graphics.getDimensions())
  CONFIG.DEBUG_ENABLED=false
  print(('Native resolution: %dx%d'):format(RENDER_W,RENDER_H))
  print('Renderer: '..table.concat({love.graphics.getRendererInfo()},' | '))
  local times,stream={},{}
  local startX,startY=px,py
  for i=1,1260 do
    px,py=startX+i*5/60,startY+i*3/60
    local start=love.timer.getTime()
    world:update(px,py)
    local generated=love.timer.getTime()-start
    eyeHeight=world:height(math.floor(px),math.floor(py))+CONFIG.CAM_HEIGHT+3
    previousPx,previousPy,previousEyeHeight=px,py,eyeHeight
    rot,pitch=i*0.007,math.rad(-20)
    love.draw();renderCanvas:newImageData():release()
    if i>60 then
      times[#times+1]=(love.timer.getTime()-start)*1000
      stream[#stream+1]=generated*1000
    end
  end
  table.sort(times);table.sort(stream)
  print(('1200 moving frames, render + readback: median %.3f ms, p99 %.3f ms, max %.3f ms'):format(times[600],times[1188],times[1200]))
  print(('Streaming: p99 %.3f ms, max %.3f ms; resident chunks <= %d'):format(stream[1188],stream[1200],world.slots^2))
end
function love.run()
  local ok,message=pcall(love.load)
  if not ok then print(message) end
  return function() return ok and 0 or 1 end
end
