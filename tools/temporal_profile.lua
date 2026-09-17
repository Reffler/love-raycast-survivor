local originalLoad=love.load
function love.load()
  originalLoad();CONFIG.DEBUG_ENABLED=false
  love.window.setMode(1920,1080,{fullscreen=false,vsync=0});love.resize(love.graphics.getDimensions())
  dayPhase=1/6
  local function frame() love.draw();renderCanvas:newImageData():release() end
  local csv=assert(io.open(os.getenv('TAA_OUTPUT')..'/profile.csv','w'))
  csv:write('view,median_ms,p99_ms,max_ms\n')
  print('Renderer: '..table.concat({love.graphics.getRendererInfo()},' | '))
  print('1920x1080, 556 blocks, 96-block shadows; 200 frames after 32 warmups; readback included')
  local function view(name,x,y,z,angle,tilt,moving)
    px,py,eyeHeight=x,y,z;rot,pitch=math.rad(angle),math.rad(tilt)
    previousPx,previousPy,previousEyeHeight=x,y,z;eyeStepOffset,previousEyeStepOffset,physicsAccumulator=0,0,0
    world:request(x,y);while world:hasPending() do world:step(256,world.upload) end
    for i=1,32 do frame() end
    local times={}
    for i=1,200 do
      if moving then px=x+i/1024;previousPx=px;rot=math.rad(angle)+i*0.00001 end
      local t=love.timer.getTime();frame();times[i]=(love.timer.getTime()-t)*1000
    end
    table.sort(times)
    local line=('%s,%.4f,%.4f,%.4f'):format(name,times[100],times[198],times[200]);print(line);csv:write(line..'\n');csv:flush()
    local data=renderCanvas:newImageData();local file=assert(io.open(os.getenv('TAA_OUTPUT')..'/'..name..'.png','wb'));file:write(data:encode('png'):getString());file:close();data:release()
  end
  local h=world:height(3,3)
  view('ground',3.5,3.5,h+1.62,0,-20)
  view('moving-ground',3.5,3.5,h+1.62,0,-20,true)
  view('horizon',3.5,3.5,h+30,45,0)
  view('downward',3.5,3.5,h+60,180,-65)
  local node
  for _,n in pairs(world.terrain.regions:get(0,0).caveNodes) do
    if n.active and n.x>=0 and n.x<1024 and n.y>=0 and n.y<1024 and (not node or n.radius>node.radius) then node=n end
  end
  assert(node,'Missing cave benchmark node')
  view('cave',node.x,node.y,node.z,0,-6)
  view('cave-ceiling',node.x,node.y,node.z,135,65)
  csv:close()
end
function love.run()
  local ok,err=pcall(love.load);world:stopWorker()
  if not ok then print(err) end
  return function() return ok and 0 or 1 end
end
