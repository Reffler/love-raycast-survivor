function love.errorhandler(message) print(message); return function() return 1 end end
-- XY DDA raycaster with heightfield fast path and sparse vertical solid spans.

local World = require("world")
-- ─────────────────── global configuration ───────────────────────────
local CONFIG = {
  -- Camera & Projection
  FOV_DEG          = 90.0,             -- Easy horizontal FOV tweak (in degrees)
  PLAYER_HEIGHT    = 1.80,              -- Physical head stays above camera
  CAM_HEIGHT       = 1.62,              -- Player eye offset from floor
  MAX_PITCH        = math.rad(89.5),   -- Vertical look clamp
  VIEW_DIST        = 556.0,             -- Max raycast distance (visibility cutoff)
  VSYNC            = true,            -- Synchronize presentation to display refresh
  MAX_FPS          = 0,              -- VSync-off limit; 0 = uncapped
  DAY_CYCLE_SECONDS = 20.0,           -- Full day + night; use 1200 for a 20-minute cycle
  SHADOWS_ENABLED  = true,
  SHADOW_DISTANCE  = 96.0,            -- Solid sun shadows; supported range 0..128 blocks
  SUN_STRENGTH     = 0.72,
  AMBIENT_STRENGTH = 0.28,

  DEBUG_ENABLED    = false,             -- Debug HUD; F3 toggles at runtime

  CAVES            = true,            -- Cached volumetric caves / entrances
  SEED             = 1337,            -- Deterministic terrain seed
  SEA_LEVEL        = 48,
  OCEAN_FLOOR      = 8,
  CONTINENT_SCALE  = 2048,            -- Blocks between continental controls
  DETAIL_HEIGHT    = 1.25,            -- 0 preserves macro geography without small detail

  -- Jump & Physics
  GRAVITY          = 32.0,             -- Downward acceleration
  JUMP_PEAK_HEIGHT = 1.2,              -- Peak jump height above launch floor (in units)
  GROUND_EPS       = 1e-3,             -- Surface contact threshold
  PLAYER_RADIUS    = 0.20,             -- Bounding box for wall collision
  STEP_SMOOTH_TIME = 0.06,             -- Visual step easing in seconds; 0 disables
  MAX_STEP_HEIGHT  = 0.25,             -- Highest surface change that can be walked onto
  FIXED_DT         = 1.0 / 120.0,      -- Deterministic physics simulation step
  MAX_FRAME_DT     = 0.1,              -- Limit catch-up work after long frame stalls

  -- Responsive FPS Movement
  MOVE_SPEED       = 25,              -- Base movement speed
  SPRINT_SPEED     = 50.0,              -- Sprint speed (Shift)
  ACCEL_GROUND     = 28.0,             -- Ground responsiveness
  ACCEL_AIR        = 18.0,             -- Mid-air steering control
  FRICTION         = 22.0,             -- Ground stop factor
  AIR_DRAG         = 5.0,              -- Air deceleration
}

-- Compute jump launch velocity derived from peak height: v = sqrt(2 * g * h)
local jumpVelocity = math.sqrt(2.0 * CONFIG.GRAVITY * CONFIG.JUMP_PEAK_HEIGHT)

-- Horizontal traversal crosses at most sqrt(2) grid planes per world-space unit.
local MAX_DDA_STEPS = math.ceil(CONFIG.VIEW_DIST * math.sqrt(2)) + 2

-- ─────────────────── state variables ────────────────────────────────
local world = World.new(CONFIG.SEED, CONFIG.VIEW_DIST, {background=true,shadowDistance=CONFIG.SHADOW_DISTANCE,caves=CONFIG.CAVES,SEA_LEVEL=CONFIG.SEA_LEVEL,
  OCEAN_FLOOR=CONFIG.OCEAN_FLOOR, CONTINENT_SCALE=CONFIG.CONTINENT_SCALE, DETAIL_HEIGHT=CONFIG.DETAIL_HEIGHT})
local SCR_W, SCR_H = 0, 0
local RENDER_W, RENDER_H = 0, 0
local renderCanvas = nil
local px, py, rot, pitch = 3.5, 3.5, 0, 0
local eyeHeight = world:height(math.floor(px), math.floor(py)) + CONFIG.CAM_HEIGHT
local yVel = 0
local flying, lastSpacePress = false, -math.huge
local velX, velY = 0, 0
local currentFloor = eyeHeight - CONFIG.CAM_HEIGHT
local physicsAccumulator = 0
local dayPhase = 1/6 -- Start at 60-degree elevation; 0 sunrise, 0.5 sunset, 0.75 midnight.
local skyTint,lightTint,sunDirection = {0,0,0},{1,1,1},{0,0,1}
local shadowCacheBounds={0,0,0,0}
local previousPx, previousPy = px, py
local previousEyeHeight = eyeHeight
-- Render-only correction for grounded step-ups; never used by collision.
local eyeStepOffset, previousEyeStepOffset = 0, 0
local lastRot, lastPitch = nil, nil
local hud, hudElapsed = nil, math.huge

-- Lightweight real-time performance counters. CPU and RAM are process-local;
-- GPU busy percentage is device-wide because LÖVE has no per-process GPU API.
local performance = {
  frameMs = 0,
  cpuPercent = 0,
  ramMB = 0,
  gpuPercent = nil,
  graphicsMemoryMB = 0,
  sampleElapsed = 0,
  lastCpuClock = os.clock(),
}

local function findGpuBusyPath()
  for card = 0, 15 do
    local path = ("/sys/class/drm/card%d/device/gpu_busy_percent"):format(card)
    local file = io.open(path, "r")
    if file then
      file:close()
      return path
    end
  end
  return nil
end

local gpuBusyPath = findGpuBusyPath()

local function readNumber(path)
  if not path then return nil end
  local file = io.open(path, "r")
  if not file then return nil end
  local value = tonumber(file:read("*l"))
  file:close()
  return value
end

local function readProcessRamMB()
  local file = io.open("/proc/self/status", "r")
  if not file then
    return collectgarbage("count") / 1024
  end

  for line in file:lines() do
    local ramKB = line:match("^VmRSS:%s+(%d+)")
    if ramKB then
      file:close()
      return tonumber(ramKB) / 1024
    end
  end
  file:close()
  return collectgarbage("count") / 1024
end

local function updatePerformanceStats(dt)
  local instantFrameMs = dt * 1000
  if performance.frameMs == 0 then
    performance.frameMs = instantFrameMs
  else
    local smoothing = math.min(1, dt * 10)
    performance.frameMs = performance.frameMs +
                          (instantFrameMs - performance.frameMs) * smoothing
  end

  performance.sampleElapsed = performance.sampleElapsed + dt
  if performance.sampleElapsed < 0.5 then return end

  local cpuClock = os.clock()
  performance.cpuPercent = math.max(
    0,
    (cpuClock - performance.lastCpuClock) / performance.sampleElapsed * 100
  )
  performance.lastCpuClock = cpuClock
  performance.ramMB = readProcessRamMB()
  performance.gpuPercent = readNumber(gpuBusyPath)

  local graphicsStats = love.graphics.getStats()
  performance.graphicsMemoryMB = (graphicsStats.texturememory or 0) / (1024 * 1024)
  performance.sampleElapsed = 0
end

-- Preallocated tables to eliminate per-frame GC allocations
local camPos     = { 0, 0, 0 }
local cacheOffset = { 0, 0 }
local camForward = { 0, 0, 0 }
local camRight   = { 0, 0, 0 }
local camUp      = { 0, 0, 0 }

local raycastShader = love.graphics.newShader("#define MAX_DDA_STEPS " .. MAX_DDA_STEPS .. "\n" ..
  assert(love.filesystem.read("raycast.glsl")))

-- ─────────────────── collision handling ────────────────────────────
local function getHighestFloorUnder(x, y, minHeight, maxHeight)
  local r = CONFIG.PLAYER_RADIUS
  local minX = math.floor(x - r) + 1
  local maxX = math.floor(x + r) + 1
  local minY = math.floor(y - r) + 1
  local maxY = math.floor(y + r) + 1

  minHeight = minHeight or -math.huge
  maxHeight = maxHeight or math.huge
  local maxH = nil
  for ix = minX, maxX do
    for iy = minY, maxY do
      local wh = world:floorBelow(ix - 1, iy - 1, maxHeight + CONFIG.GROUND_EPS)
      if wh then
        if wh >= minHeight - CONFIG.GROUND_EPS and
           wh <= maxHeight + CONFIG.GROUND_EPS and
           (maxH == nil or wh > maxH) then
          maxH = wh
        end
      end
    end
  end
  return maxH
end

local function isPointColliding(x, y, footH, canStep)
  local r = CONFIG.PLAYER_RADIUS
  local minX = math.floor(x - r) + 1
  local maxX = math.floor(x + r) + 1
  local minY = math.floor(y - r) + 1
  local maxY = math.floor(y + r) + 1

  local foot=footH
  if canStep then foot=math.max(foot,getHighestFloorUnder(x,y,-math.huge,currentFloor+CONFIG.MAX_STEP_HEIGHT) or foot) end
  for ix = minX, maxX do
    for iy = minY, maxY do
      if world:overlaps(ix-1,iy-1,foot+CONFIG.GROUND_EPS,foot+CONFIG.PLAYER_HEIGHT) then return true end
    end
  end
  return false
end

local function getLowestCeiling(x,y,head)
  local r=CONFIG.PLAYER_RADIUS;local ceiling=math.huge
  for ix=math.floor(x-r),math.floor(x+r) do for iy=math.floor(y-r),math.floor(y+r) do
    ceiling=math.min(ceiling,world:ceilingAbove(ix,iy,head+CONFIG.PLAYER_HEIGHT-CONFIG.CAM_HEIGHT-CONFIG.GROUND_EPS) or math.huge)
  end end
  return ceiling-(CONFIG.PLAYER_HEIGHT-CONFIG.CAM_HEIGHT)
end

local function move(dx, dy, canStep)
  if dx == 0 and dy == 0 then return end
  -- Backpressure only if generation cannot keep up: never enter recycled terrain.
  if world.worker and not world:canRender(px+dx,py+dy) then return end
  local footH = eyeHeight - CONFIG.CAM_HEIGHT
  local maxStep = CONFIG.PLAYER_RADIUS * 0.5
  local steps = math.max(1, math.ceil(math.max(math.abs(dx), math.abs(dy)) / maxStep))
  local stepX, stepY = dx / steps, dy / steps

  for _ = 1, steps do
    if not isPointColliding(px + stepX, py, footH, canStep) then
      px = px + stepX
    else
      velX = 0
      stepX = 0
    end

    if not isPointColliding(px, py + stepY, footH, canStep) then
      py = py + stepY
    else
      velY = 0
      stepY = 0
    end
  end
end

function love.keypressed(key, _, isrepeat)
  if isrepeat then return end
  if key == "space" then
    local now = love.timer.getTime()
    if now - lastSpacePress <= 0.3 then
      flying = not flying
      yVel, eyeStepOffset, previousEyeStepOffset = 0, 0, 0
      lastSpacePress = -math.huge
    else
      lastSpacePress = now
    end
  elseif key == "f3" then
    CONFIG.DEBUG_ENABLED = not CONFIG.DEBUG_ENABLED
    performance.lastCpuClock = os.clock()
    performance.sampleElapsed = 0
    hudElapsed = math.huge
  end
end

-- ─────────────────── viewport update ────────────────────────────────
local function updateProjection(w, h)
  SCR_W, SCR_H = w, h
  RENDER_W, RENDER_H = love.graphics.getPixelDimensions()

  if not renderCanvas or renderCanvas:getWidth() ~= RENDER_W or renderCanvas:getHeight() ~= RENDER_H then
    if renderCanvas then renderCanvas:release() end
    renderCanvas = love.graphics.newCanvas(RENDER_W, RENDER_H, { format="rgba8", msaa=0, dpiscale=1 })
    renderCanvas:setFilter("nearest", "nearest")
  end

  local hfovRad = math.rad(CONFIG.FOV_DEG)
  local tanHalfHFOV = math.tan(hfovRad * 0.5)
  local tanHalfVFOV = tanHalfHFOV * (RENDER_H / RENDER_W)

  raycastShader:send("tanHalfHFOV", tanHalfHFOV)
  raycastShader:send("tanHalfVFOV", tanHalfVFOV)
end

function love.resize(w, h)
  updateProjection(w, h)
end

-- ─────────────────── engine lifecycle ───────────────────────────────
function love.load()
  assert(type(CONFIG.SHADOW_DISTANCE)=='number' and CONFIG.SHADOW_DISTANCE>=0 and CONFIG.SHADOW_DISTANCE<=128,
    'SHADOW_DISTANCE must be within 0..128 blocks')
  assert(type(CONFIG.DAY_CYCLE_SECONDS)=='number' and CONFIG.DAY_CYCLE_SECONDS>0 and CONFIG.DAY_CYCLE_SECONDS<math.huge,
    'DAY_CYCLE_SECONDS must be positive and finite')
  local dw, dh = love.window.getDesktopDimensions()
  love.window.setMode(dw, dh, {
    fullscreen = true,
    fullscreentype = "desktop",
    vsync = CONFIG.VSYNC and 1 or 0,
    msaa = 0
  })
  love.mouse.setRelativeMode(true)
  love.graphics.setBackgroundColor(0.48, 0.72, 0.92, 1)
  local font = love.graphics.newFont("Px437_IBM_VGA_8x16.ttf", 16)
  font:setFilter("nearest", "nearest")
  love.graphics.setFont(font)

  updateProjection(love.graphics.getDimensions())

  world:initGraphics(px, py)
  raycastShader:send("heightTex", world.texture)
  raycastShader:send("chunkMaxTex", world.maxTexture)
  raycastShader:send("cacheSize", world.size)
  raycastShader:send("maxHeight", world.maxHeight)
  raycastShader:send("viewDist", CONFIG.VIEW_DIST)
  for uniform,file in pairs({dirtTex="dirt",grassSideTex="grass_block_side",grassTopTex="grass_block_top"}) do
    local texture=love.graphics.newImage("textures/"..file..".png")
    texture:setFilter("nearest","nearest");texture:setWrap("repeat","repeat")
    raycastShader:send(uniform,texture)
  end
  -- Pay first-use shader/driver work during loading, before interactive frames.
  love.draw();renderCanvas:newImageData():release()
end

function love.mousemoved(_, _, dx, dy)
  rot = (rot + dx * 0.002) % (2 * math.pi)
  pitch = math.max(-CONFIG.MAX_PITCH, math.min(CONFIG.MAX_PITCH, pitch - dy * 0.002))
end

local function updatePhysics(dt)
  eyeStepOffset = CONFIG.STEP_SMOOTH_TIME > 0 and eyeStepOffset * math.exp(-dt / CONFIG.STEP_SMOOTH_TIME) or 0
  -- Resolve walkable support without considering taller neighboring walls.
  local footHeight = eyeHeight - CONFIG.CAM_HEIGHT
  local grounded = math.abs(footHeight - currentFloor) <= CONFIG.GROUND_EPS and yVel <= 0
  local walkableFloor = getHighestFloorUnder(
    px, py, -math.huge, currentFloor + CONFIG.MAX_STEP_HEIGHT
  )

  if flying then
    grounded = false
  elseif grounded and walkableFloor == nil then
    grounded = false
  elseif grounded and walkableFloor > currentFloor + CONFIG.GROUND_EPS then
    currentFloor = walkableFloor
    if CONFIG.STEP_SMOOTH_TIME > 0 then eyeStepOffset = eyeStepOffset + eyeHeight - (CONFIG.CAM_HEIGHT + currentFloor) end
    eyeHeight = CONFIG.CAM_HEIGHT + currentFloor
  elseif grounded and walkableFloor < currentFloor - CONFIG.GROUND_EPS then
    -- The player walked off a ledge. Keep their height and begin falling.
    currentFloor = walkableFloor
    grounded = false
  end

  if love.keyboard.isDown("space") and grounded and yVel <= 0 then
    yVel = jumpVelocity
    grounded = false
  end

  -- Horizontal inputs
  local inputX = (love.keyboard.isDown("d") and 1 or 0) - (love.keyboard.isDown("a") and 1 or 0)
  local inputY = (love.keyboard.isDown("w") and 1 or 0) - (love.keyboard.isDown("s") and 1 or 0)

  local inputLen = math.sqrt(inputX * inputX + inputY * inputY)
  local wishDirX, wishDirY = 0, 0
  if inputLen > 0 then
    inputX = inputX / inputLen
    inputY = inputY / inputLen
    local s, c = math.sin(rot), math.cos(rot)
    wishDirX = inputY * c - inputX * s
    wishDirY = inputY * s + inputX * c
  end

  local shift = love.keyboard.isDown("lshift", "rshift")
  local targetSpeed = ((grounded or flying) and shift) and CONFIG.SPRINT_SPEED or CONFIG.MOVE_SPEED
  local currentAccel = (grounded or flying) and CONFIG.ACCEL_GROUND or CONFIG.ACCEL_AIR
  local currentDrag  = (grounded or flying) and CONFIG.FRICTION or CONFIG.AIR_DRAG

  -- Linear drag simplifies to one shared multiplier; no length or division needed.
  local damping = math.max(1 - currentDrag * dt, 0)
  velX, velY = velX * damping, velY * damping

  -- Directional acceleration
  if inputLen > 0 then
    local currentWishSpeed = velX * wishDirX + velY * wishDirY
    local addSpeed = targetSpeed - currentWishSpeed
    if addSpeed > 0 then
      local accelSpeed = math.min(currentAccel * targetSpeed * dt, addSpeed)
      velX = velX + accelSpeed * wishDirX
      velY = velY + accelSpeed * wishDirY
    end
  end

  local oldPx, oldPy = px, py
  move(velX * dt, velY * dt, grounded)

  if flying then
    local vertical = (love.keyboard.isDown("space") and 1 or 0) -
                     (love.keyboard.isDown("lctrl", "rctrl") and 1 or 0)
    currentFloor = getHighestFloorUnder(px, py, -math.huge, eyeHeight-CONFIG.CAM_HEIGHT+CONFIG.GROUND_EPS) or 0
    local ceiling=getLowestCeiling(px,py,eyeHeight)
    eyeHeight = math.min(ceiling,math.max(currentFloor + CONFIG.CAM_HEIGHT, eyeHeight + vertical * targetSpeed * dt))
    yVel = 0
    return
  end

  -- Recheck support only after movement changes the player footprint.
  if grounded and (px ~= oldPx or py ~= oldPy) then
    walkableFloor = getHighestFloorUnder(
      px, py, -math.huge, currentFloor + CONFIG.MAX_STEP_HEIGHT
    )
    if walkableFloor == nil then
      grounded = false
    elseif walkableFloor > currentFloor + CONFIG.GROUND_EPS then
      currentFloor = walkableFloor
      if CONFIG.STEP_SMOOTH_TIME > 0 then eyeStepOffset = eyeStepOffset + eyeHeight - (CONFIG.CAM_HEIGHT + currentFloor) end
      eyeHeight = CONFIG.CAM_HEIGHT + currentFloor
    elseif walkableFloor < currentFloor - CONFIG.GROUND_EPS then
      currentFloor = walkableFloor
      grounded = false
    end
  end

  local previousFootHeight = eyeHeight - CONFIG.CAM_HEIGHT
  if grounded then
    yVel = 0
    eyeHeight = CONFIG.CAM_HEIGHT + currentFloor
  else
    yVel = yVel - CONFIG.GRAVITY * dt
    local nextFootHeight = previousFootHeight + yVel * dt
    if yVel>0 then
      local ceiling=getLowestCeiling(px,py,eyeHeight)
      if nextFootHeight+CONFIG.CAM_HEIGHT>ceiling then nextFootHeight=ceiling-CONFIG.CAM_HEIGHT;yVel=0 end
    end

    -- Only a downward crossing can land on a surface, including a tall block.
    local landingFloor = nil
    if yVel <= 0 then
      landingFloor = getHighestFloorUnder(px, py, nextFootHeight, previousFootHeight)
    end

    if landingFloor ~= nil then
      currentFloor = landingFloor
      eyeHeight = CONFIG.CAM_HEIGHT + landingFloor
      yVel = 0
    else
      eyeHeight = CONFIG.CAM_HEIGHT + nextFootHeight
    end
  end
end

function love.update(dt)
  world.shadowDistance=CONFIG.SHADOWS_ENABLED and CONFIG.SHADOW_DISTANCE or 0
  dayPhase=(dayPhase+dt/CONFIG.DAY_CYCLE_SECONDS)%1
  if not world.worker then world:startWorker() end
  hudElapsed = hudElapsed + dt
  if CONFIG.DEBUG_ENABLED then updatePerformanceStats(dt) end
  physicsAccumulator = physicsAccumulator + math.min(dt, CONFIG.MAX_FRAME_DT)

  while physicsAccumulator >= CONFIG.FIXED_DT do
    previousPx, previousPy = px, py
    previousEyeHeight = eyeHeight
    previousEyeStepOffset = eyeStepOffset
    updatePhysics(CONFIG.FIXED_DT)
    physicsAccumulator = physicsAccumulator - CONFIG.FIXED_DT
  end

  world:update(px, py)

  if love.keyboard.isDown("escape") then
    love.event.quit()
  end
end

function love.quit()
  world:stopWorker()
end

function love.draw()
  local angle=dayPhase*math.pi*2
  sunDirection[1],sunDirection[2],sunDirection[3]=math.cos(angle)*0.8,math.cos(angle)*0.6,math.sin(angle)
  local daylight=math.max(0,math.min(1,(sunDirection[3]+0.15)/0.4))
  daylight=daylight*daylight*(3-2*daylight)
  local twilight=math.max(0,1-math.abs(sunDirection[3])/0.3)
  local warmth=twilight*0.6
  skyTint[1]=(0.015+0.465*daylight)*(1-warmth)+0.65*warmth
  skyTint[2]=(0.025+0.695*daylight)*(1-warmth)+0.25*warmth
  skyTint[3]=(0.07+0.85*daylight)*(1-warmth)+0.14*warmth
  lightTint[1]=0.16+0.84*daylight
  lightTint[2]=0.20+0.80*daylight-0.12*twilight
  lightTint[3]=0.30+0.70*daylight-0.20*twilight
  if raycastShader:hasUniform('skyTint') then raycastShader:send('skyTint',skyTint) end
  if raycastShader:hasUniform('lightTint') then raycastShader:send('lightTint',lightTint) end
  raycastShader:send('sunDirection',sunDirection)
  -- Fade direct light from zero at 12 degrees to full strength at 18 degrees.
  local sunFade=math.max(0,math.min(1,(sunDirection[3]-0.20791169)/(0.30901699-0.20791169)))
  if raycastShader:hasUniform('sunStrength') then raycastShader:send('sunStrength',CONFIG.SUN_STRENGTH*sunFade) end
  if raycastShader:hasUniform('ambientStrength') then raycastShader:send('ambientStrength',CONFIG.AMBIENT_STRENGTH) end
  if raycastShader:hasUniform('shadowsEnabled') then raycastShader:send('shadowsEnabled',CONFIG.SHADOWS_ENABLED) end
  if raycastShader:hasUniform('shadowDistance') then raycastShader:send('shadowDistance',CONFIG.SHADOW_DISTANCE) end
  local interpolationAlpha = physicsAccumulator / CONFIG.FIXED_DT
  local renderPx = previousPx + (px - previousPx) * interpolationAlpha
  local renderPy = previousPy + (py - previousPy) * interpolationAlpha
  local renderEyeHeight = previousEyeHeight +
                          (eyeHeight - previousEyeHeight) * interpolationAlpha +
                          previousEyeStepOffset + (eyeStepOffset - previousEyeStepOffset) * interpolationAlpha
  if rot ~= lastRot or pitch ~= lastPitch then
    local cp, sp = math.cos(pitch), math.sin(pitch)
    local cr, sr = math.cos(rot), math.sin(rot)
    camForward[1], camForward[2], camForward[3] = cp * cr, cp * sr, sp
    camRight[1], camRight[2], camRight[3] = -sr, cr, 0
    camUp[1], camUp[2], camUp[3] = -sp * cr, -sp * sr, cp
    raycastShader:send("camForward", camForward)
    raycastShader:send("camRight", camRight)
    raycastShader:send("camUp", camUp)
    lastRot, lastPitch = rot, pitch
  end

  -- Keep GPU coordinates near zero, even far from spawn.
  local originX, originY = math.floor(renderPx / 16) * 16, math.floor(renderPy / 16) * 16
  camPos[1], camPos[2], camPos[3] = renderPx - originX, renderPy - originY, renderEyeHeight
  cacheOffset[1], cacheOffset[2] = originX % world.size, originY % world.size
  raycastShader:send("camPos", camPos)
  raycastShader:send("cacheOffset", cacheOffset)
  shadowCacheBounds[1],shadowCacheBounds[2]=(world.cx-world.radius)*16-originX,(world.cy-world.radius)*16-originY
  shadowCacheBounds[3],shadowCacheBounds[4]=(world.cx+world.radius+1)*16-originX,(world.cy+world.radius+1)*16-originY
  if raycastShader:hasUniform('shadowCacheBounds') then raycastShader:send('shadowCacheBounds',shadowCacheBounds) end

  love.graphics.setCanvas(renderCanvas)
  love.graphics.setBlendMode("replace", "premultiplied") -- Full-screen shader overwrites every pixel.
  love.graphics.setColor(1, 1, 1, 1)
  world:bindSpans(raycastShader)
  love.graphics.setShader(raycastShader)
  love.graphics.rectangle("fill", 0, 0, RENDER_W, RENDER_H)
  love.graphics.setShader()
  love.graphics.setBlendMode("alpha")

  -- Rebuild text at 10 Hz instead of formatting and laying it out every frame.
  if CONFIG.DEBUG_ENABLED and hudElapsed >= 0.1 then
    hudElapsed = 0
    if not hud then hud = love.graphics.newText(love.graphics.getFont()) end
    hud:clear()
    hud:add(("Pitch: %.1f° | FOV: %d°"):format(math.deg(pitch), CONFIG.FOV_DEG), 0, 0)
    hud:add(("FPS: %d | Frame: %.2f ms"):format(
      love.timer.getFPS(), performance.frameMs
    ), 0, 20)

    local gpuText = performance.gpuPercent and
                    ("%.1f%% (device)"):format(performance.gpuPercent) or "N/A"
    hud:add(("CPU: %.1f%% | GPU: %s"):format(
      performance.cpuPercent, gpuText
    ), 0, 40)
    hud:add(("RAM: %.1f MB | Gfx: %.1f MB"):format(
      performance.ramMB, performance.graphicsMemoryMB
    ), 0, 60)
    hud:add(("Eye Z: %.2f (Peak Jump: +%.2f)"):format(
      eyeHeight, CONFIG.JUMP_PEAK_HEIGHT
    ), 0, 80)
    hud:add(("Speed: %.2f"):format(
      math.sqrt(velX * velX + velY * velY)
    ), 0, 100)
  end
  if CONFIG.DEBUG_ENABLED then
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(hud, 10, 10)
  end

  love.graphics.setCanvas()

  love.graphics.setBlendMode("replace", "premultiplied")
  love.graphics.draw(renderCanvas, 0, 0, 0, SCR_W / RENDER_W, SCR_H / RENDER_H)
  love.graphics.setShader()
  love.graphics.setBlendMode("alpha")
end

-- Advance a shared deadline to absorb sleep jitter without losing average FPS.
-- Rebase after a missed interval so long stalls cannot trigger catch-up bursts.
-- VSync owns pacing when enabled. Unfocused/minimized windows always yield.
function love.run()
  assert(type(CONFIG.MAX_FPS) == "number" and CONFIG.MAX_FPS >= 0 and CONFIG.MAX_FPS < math.huge,
    "CONFIG.MAX_FPS must be a finite non-negative number")
  if love.load then love.load(love.arg.parseGameArguments(arg), arg) end
  local frameInterval = not CONFIG.VSYNC and CONFIG.MAX_FPS > 0 and 1 / CONFIG.MAX_FPS or 0
  love.timer.step()
  local nextFrame = frameInterval > 0 and love.timer.getTime() or 0
  return function()
    local frameStart = frameInterval > 0 and love.timer.getTime()
    if frameStart then
      if frameStart - nextFrame >= frameInterval then nextFrame = frameStart end
      nextFrame = nextFrame + frameInterval
    end
    love.event.pump()
    for name, a, b, c, d, e, f in love.event.poll() do
      if name == "quit" then
        if not love.quit or not love.quit() then return a or 0 end
      else
        love.handlers[name](a, b, c, d, e, f)
      end
    end
    local dt = love.timer.step()
    love.update(dt)
    if love.graphics.isActive() then
      love.graphics.origin()
      love.draw()
      love.graphics.present()
    end
    local deadline = frameStart and nextFrame or 0
    if not love.window.hasFocus() or not love.graphics.isActive() then
      deadline = math.max(deadline, love.timer.getTime() + 0.01)
      nextFrame = deadline
    end
    if deadline > 0 then
      local remaining = deadline - love.timer.getTime()
      while remaining > 0 do
        love.timer.sleep(math.max(remaining, 0.001)) -- SDL may truncate fractional milliseconds.
        remaining = deadline - love.timer.getTime()
      end
    end
  end
end

CONFIG.SHADOW_DISTANCE=0
CONFIG.SHADOWS_ENABLED=false

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
