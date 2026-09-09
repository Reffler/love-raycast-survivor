
-- Appended to main.lua in an isolated copy; locals remain accessible.
local originalLoad = love.load
function love.load()
  originalLoad()
  love.window.setMode(960, 540, {vsync = 0})
  CONFIG.RENDER_SCALE = 1
  love.resize(960, 540)
  print('Renderer: ' .. table.concat({love.graphics.getRendererInfo()}, ' | '))
  local cases = {{3.5,3.5,0.5,0,0}, {3.5,3.5,0.5,0,-30},
    {3.5,3.5,0.5,0,60}, {5.5,6.5,2.5,0,-35},
    {3.5,3.5,0.5,90,0}, {3.5,3.5,0.5,0,89.5},
    {3.5,3.5,0.5,0,-89.5}, {6.5,8.5,3.5,180,-30},
    {-1,5,0.5,0,0}, {3,3,1,45,0},
    {6,4.5,1,180,0}, {7,4.5,1,180,0}}
  for i,c in ipairs(cases) do
    px,py,eyeHeight,rot,pitch = c[1],c[2],c[3],math.rad(c[4]),math.rad(c[5])
    previousPx,previousPy,previousEyeHeight = px,py,eyeHeight
    for j=1,100 do love.draw() end
    renderCanvas:newImageData():release()
    local times={}
    for rep=1,5 do
      local start=love.timer.getTime()
      for j=1,300 do love.draw() end
      renderCanvas:newImageData():release()
      times[rep]=(love.timer.getTime()-start)*1000/300
    end
    table.sort(times)
    print(('Case %d: %.3f ms'):format(i,times[3]))
    local data=renderCanvas:newImageData()
    local reference = os.getenv("RAYCAST_REFERENCE")
    local oldFile = reference ~= "" and io.open(reference.."/case-"..i..".png", "rb")
    assert(reference == "" or oldFile, "Missing reference frame")
    if oldFile then
      local old=love.image.newImageData(love.filesystem.newFileData(oldFile:read('*a'),'old.png'));oldFile:close()
      local ffi=require('ffi')
      local a,b=ffi.cast('uint8_t*',old:getFFIPointer()),ffi.cast('uint8_t*',data:getFFIPointer())
      local total,changed,maxDiff=0,0,0
      for pixel=0,960*540-1 do
        local peak=0
        for channel=0,2 do
          local diff=math.abs(a[pixel*4+channel]-b[pixel*4+channel])
          total=total+diff;peak=math.max(peak,diff)
        end
        if peak>3 then changed=changed+1 end
        maxDiff=math.max(maxDiff,peak)
      end
      print(('Diff %d: mean %.5f, pixels >3: %d, max %d'):format(i,total/(960*540*3),changed,maxDiff))
      old:release()
      -- Nearest-neighbor texture boundaries can move by a few floating-point ULPs.
      assert(changed <= 960*540*0.0001, "More than 0.01% of pixels differ by >3/255")
    end
    local file=data:encode('png')
    local out=assert(io.open(os.getenv("RAYCAST_OUTPUT").."/case-"..i..'.png','wb'))
    out:write(file:getString());out:close();data:release();file:release()
  end
  love.event.quit()
end
