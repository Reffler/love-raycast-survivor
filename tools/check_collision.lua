-- Run from project root: luajit tools/check_collision.lua
local file = assert(io.open("main.lua", "r"))
local source = file:read("*a")
file:close()
local prefix = source:sub(1, assert(source:find("-- Lightweight", 1, true)) - 1)
local collision = source:match("(local function getHighestFloorUnder.-)\n%-%- [^\n]*viewport update")
local physics = source:match("(local function updatePhysics.-)\nfunction love.update")
assert(collision and physics, "Physics functions missing")
local tests = [=[
local function reset(x, y, feet, support, verticalSpeed)
  px, py, eyeHeight = x, y, feet + CONFIG.CAM_HEIGHT
  currentFloor, yVel, velX, velY, rot = support, verticalSpeed or 0, 0, 0, 0
  keys = {}
end
local function clearLevel()
  for x = 1, levelW do for y = 1, levelH do level[x][y] = 0 end end
end
local function outsideWalls()
  local feet = eyeHeight - CONFIG.CAM_HEIGHT
  local floor = getHighestFloorUnder(px, py) or 0
  assert(feet >= floor - CONFIG.GROUND_EPS,
    ("Wall penetration: feet %.6f, wall %.6f at %.6f, %.6f"):format(feet, floor, px, py))
end
clearLevel()
-- Falling from a previously occupied 3-unit ledge toward a 2-unit wall side.
level[7][5] = 2
reset(5.79, 4.5, 1.8, 3, -2)
keys.w = true
for i = 1, 120 do updatePhysics(CONFIG.FIXED_DT); outsideWalls() end
assert(px < 5.8, "Falling player crossed wall side")

-- Same failure along Y.
clearLevel(); level[5][7] = 2
reset(4.5, 5.79, 1.8, 3, -2); keys.d = true
for i = 1, 120 do updatePhysics(CONFIG.FIXED_DT); outsideWalls() end
assert(py < 5.8, "Falling player crossed Y wall side")

-- Rising players also cannot use the stale launch surface to step through walls.
clearLevel(); level[7][5] = 2
reset(5.79, 4.5, 1.7, 3, 1); keys.w = true
for i = 1, 60 do updatePhysics(CONFIG.FIXED_DT); outsideWalls() end

-- Reproduce through actual takeoff from a tall ledge, flight, and descent.
clearLevel(); level[5][5] = 3; level[9][5] = 2
reset(4.5, 4.5, 3, 3); keys.w = true; keys.space = true
updatePhysics(CONFIG.FIXED_DT); keys.space = false
for i = 1, 180 do updatePhysics(CONFIG.FIXED_DT); outsideWalls() end
assert(px < 7.8, "Jump from tall ledge bypassed lower wall")

-- Descending from above must land on every supported wall height, even at speed.
for height = 1, 3 do
  clearLevel(); level[7][5] = height
  reset(6.5, 4.5, height + 0.05, 0, -30)
  updatePhysics(CONFIG.FIXED_DT)
  assert(math.abs(eyeHeight - CONFIG.CAM_HEIGHT - height) < 1e-9)
  assert(currentFloor == height and yVel == 0)
end

-- Entering footprint from above and crossing top in the same tick is a landing.
clearLevel(); level[7][5] = 2
reset(5.79, 4.5, 2.02, 3, -5); velX = 3; keys.w = true
updatePhysics(CONFIG.FIXED_DT); outsideWalls()
assert(currentFloor == 2 and yVel == 0)

-- Grounded step-up remains legal; airborne step-up must remain blocked.
WALL_HEIGHTS[4] = 0.2
clearLevel(); level[7][5] = 4
reset(5.79, 4.5, 0, 0); keys.w = true
for i = 1, 20 do updatePhysics(CONFIG.FIXED_DT); outsideWalls() end
assert(currentFloor == 0.2)
reset(5.79, 4.5, 0.1, 0, -1); velX = 3; keys.w = true
updatePhysics(CONFIG.FIXED_DT); outsideWalls()
assert(px < 5.8, "Airborne player stepped into low obstacle")
print("PASS: falling/rising side collision, both axes, top landings, fast falls, grounded steps, airborne obstacles")
]=]
local mock = [[
local keys = {}
local love = { keyboard = { isDown = function(...)
  for i = 1, select('#', ...) do if keys[select(i, ...)] then return true end end
  return false
end } }
]]
-- Compile real production physics with controlled input and map; no GPU required.
assert(loadstring(mock .. prefix .. "local levelW, levelH = #level, #level[1]\n" .. collision .. physics .. tests))()
