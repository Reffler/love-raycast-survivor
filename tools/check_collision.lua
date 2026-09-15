local file=assert(io.open('main.lua'));local source=file:read('*a');file:close()
local prefix=source:sub(1,assert(source:find('-- Lightweight',1,true))-1)
local collision=assert(source:match('(local function getHighestFloorUnder.-)\n%-%- [^\n]*viewport update'))
local physics=assert(source:match('(local function updatePhysics.-)\nfunction love.update'))
local mock=[[local keys={};local now=0;local love={timer={getTime=function() return now end},keyboard={isDown=function(...)
  for i=1,select('#',...) do if keys[select(i,...)] then return true end end
  return false
end}}]]
local tests=[[
local terrain=function() return 0 end
world.height=function(_,x,y) return terrain(x,y) end
world.floorBelow=function(_,x,y,z) local h=terrain(x,y);return h<=z and h or nil end
world.ceilingAbove=function() return nil end
world.overlaps=function(_,x,y,lo,hi) return lo<terrain(x,y)-0.00001 and hi>0 end
local function reset(x,y,z)
  px,py,eyeHeight,currentFloor=x,y,z+CONFIG.CAM_HEIGHT,z
  velX,velY,yVel,rot,eyeStepOffset,previousEyeStepOffset=0,0,0,0,0,0;keys={}
  flying,lastSpacePress=false,-math.huge
end
terrain=function(x) return x>=1 and 1 or 0 end
reset(0.5,0.5,0);keys.w=true
for i=1,120 do updatePhysics(CONFIG.FIXED_DT) end
assert(px<0.81,'Walk crossed full block')
keys.space=true;updatePhysics(CONFIG.FIXED_DT);keys.space=false
for i=1,100 do updatePhysics(CONFIG.FIXED_DT) end
assert(px>1.2 and currentFloor==1 and yVel==0,'Jump failed to climb full block')
keys.w=false;keys.s=true
for i=1,180 do updatePhysics(CONFIG.FIXED_DT) end
assert(px<0 and currentFloor==0 and yVel==0,'Failed to descend')
terrain=function(x,y) return y>=-16 and 2 or 0 end
reset(0.5,-16.21,1.8);currentFloor=3;yVel=-2;keys.d=true
for i=1,120 do updatePhysics(CONFIG.FIXED_DT) end
assert(py<-16.19,'Falling player crossed block side at negative chunk seam')
terrain=function() return 5 end
reset(16,16,5.1);yVel=-30;updatePhysics(CONFIG.FIXED_DT)
assert(currentFloor==5 and yVel==0,'Fast fall missed terrain')
terrain=function() return 0 end
reset(0.5,0.5,3)
now=1;love.keypressed('space');assert(not flying,'Single tap enabled flight')
now=1.1;love.keypressed('space',nil,true);assert(not flying,'Key repeat enabled flight')
now=1.4;love.keypressed('space');assert(not flying,'Slow double tap enabled flight')
now=1.6;love.keypressed('space');assert(flying,'Double tap failed to enable flight')
local height=eyeHeight
for i=1,120 do updatePhysics(CONFIG.FIXED_DT) end
assert(eyeHeight==height and yVel==0,'Hover drifted')
keys.space=true
for i=1,120 do updatePhysics(CONFIG.FIXED_DT) end
assert(math.abs(eyeHeight-height-CONFIG.MOVE_SPEED)<1e-8,'Space failed to raise flight height')
keys.space=false;keys.rctrl=true
for i=1,120 do updatePhysics(CONFIG.FIXED_DT) end
assert(math.abs(eyeHeight-height)<1e-8,'Ctrl failed to lower flight height')
keys.space=true;updatePhysics(CONFIG.FIXED_DT)
assert(math.abs(eyeHeight-height)<1e-8,'Opposite vertical inputs should cancel')
keys.space=false;keys.rctrl=false;keys.w=true;keys.lshift=true
for i=1,120 do updatePhysics(CONFIG.FIXED_DT) end
assert(math.abs(velX-CONFIG.SPRINT_SPEED)<1e-8,'Shift failed to sprint in flight')
keys={lctrl=true}
for i=1,300 do updatePhysics(CONFIG.FIXED_DT) end
assert(eyeHeight==CONFIG.CAM_HEIGHT,'Flight descended through ground')
local wallX=math.ceil(px+CONFIG.PLAYER_RADIUS)+1
terrain=function(x) return x>=wallX and 2 or 0 end
keys={w=true}
for i=1,120 do updatePhysics(CONFIG.FIXED_DT) end
assert(px<=wallX-CONFIG.PLAYER_RADIUS+CONFIG.GROUND_EPS,'Flight crossed terrain wall')
terrain=function() return 0 end
keys={};eyeHeight=10;now=2;love.keypressed('space');now=2.1;love.keypressed('space')
assert(not flying,'Double tap failed to disable flight')
updatePhysics(CONFIG.FIXED_DT);assert(yVel<0 and eyeHeight<10,'Gravity failed to resume')
reset(0.5,0.5,0);keys={w=true,rshift=true}
for i=1,120 do updatePhysics(CONFIG.FIXED_DT) end
assert(math.abs(velX-CONFIG.SPRINT_SPEED)<1e-8,'Ground sprint regressed')
print('PASS: double-tap toggle, repeat rejection, hover, rise, descend, flight/ground sprint, terrain collision, gravity resume')
world=World.new(CONFIG.SEED,CONFIG.VIEW_DIST)
for _,position in ipairs({{15.5,15.5},{-16.5,-16.5},{1000000.5,-1000000.5}}) do
  local x,y=unpack(position);reset(x,y,world:height(math.floor(x),math.floor(y)))
  keys.w=true;keys.space=true
  for i=1,1000 do
    updatePhysics(CONFIG.FIXED_DT)
    assert(eyeHeight-CONFIG.CAM_HEIGHT>=getHighestFloorUnder(px,py)-0.001,'Terrain penetration')
  end
end
print('PASS: solid block sides, jump ascent, descent, negative seam collision, fast landing, generated terrain traversal')

world=World.new(1337,16,{caves=false})
for cy=-1,1 do for cx=-1,1 do
  local c=world:generateChunk(cx,cy);c.complex=true
  for i=0,255 do
    local k=i*8;for j=0,7 do c.spans[k+j]=-1 end
    c.spans[k],c.spans[k+1]=0,10
    c.spans[k+2],c.spans[k+3]=(cx*16+i%16>=4 and 11 or 13),40
  end
end end
assert(world:isSolid(0,0,9) and not world:isSolid(0,0,11) and world:isSolid(0,0,14),'Cave solidity wrong')
assert(world:floorBelow(0,0,12)==10 and world:ceilingAbove(0,0,12)==13,'Cave bounds wrong')
reset(0.5,0.5,10);keys.space=true
for i=1,90 do updatePhysics(CONFIG.FIXED_DT);assert(eyeHeight<=13+1e-8,'Jump crossed cave ceiling');keys.space=false end
assert(currentFloor==10 and yVel==0,'Cave landing failed')
flying=true;keys={space=true}
for i=1,120 do updatePhysics(CONFIG.FIXED_DT) end
assert(math.abs(eyeHeight-(13-CONFIG.PLAYER_HEIGHT+CONFIG.CAM_HEIGHT))<1e-8,'Flight crossed cave ceiling')
keys={lctrl=true};for i=1,120 do updatePhysics(CONFIG.FIXED_DT) end
assert(eyeHeight==10+CONFIG.CAM_HEIGHT,'Flight crossed cave floor')
keys={w=true};for i=1,240 do updatePhysics(CONFIG.FIXED_DT) end
assert(px>2 and px<3.81,'Cave movement or low-ceiling wall collision failed')
print('PASS: span floors/ceilings, cave jumps/landing, flight, walking and low overhang collision')
]]
assert(loadstring(mock..prefix..collision..physics..tests))()
