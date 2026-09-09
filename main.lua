-- Heightfield GPU raycaster with true perspective pitch.

local level = require("levels")[1]

-- ─────────────────── global configuration ───────────────────────────
local CONFIG = {
  -- Camera & Projection
  FOV_DEG          = 90.0,             -- Easy horizontal FOV tweak (in degrees)
  CAM_HEIGHT       = 0.5,              -- Player eye offset from floor
  MAX_PITCH        = math.rad(89.5),   -- Vertical look clamp
  VIEW_DIST        = 16.0,             -- Max raycast distance (fog cutoff)
  RENDER_SCALE     = 0.25,              -- Internal 3D resolution (0.5 = 25% of window pixels)
  VSYNC            = false,            -- Synchronize presentation to display refresh
  MAX_FPS          = 333,              -- VSync-off limit; 0 = uncapped
  
  -- Jump & Physics
  GRAVITY          = 18.0,             -- Downward acceleration
  JUMP_PEAK_HEIGHT = 1.2,              -- Peak jump height above launch floor (in units)
  GROUND_EPS       = 1e-3,             -- Surface contact threshold
  PLAYER_RADIUS    = 0.20,             -- Bounding box for wall collision
  MAX_STEP_HEIGHT  = 0.25,             -- Highest surface change that can be walked onto
  FIXED_DT         = 1.0 / 120.0,      -- Deterministic physics simulation step
  MAX_FRAME_DT     = 0.1,              -- Limit catch-up work after long frame stalls
  
  -- Responsive FPS Movement
  MOVE_SPEED       = 3.2,              -- Base movement speed
  SPRINT_SPEED     = 5.0,              -- Sprint speed (Shift)
  ACCEL_GROUND     = 28.0,             -- Ground responsiveness
  ACCEL_AIR        = 18.0,             -- Mid-air steering control
  FRICTION         = 22.0,             -- Ground stop factor
  AIR_DRAG         = 5.0,              -- Air deceleration
}

-- Compute jump launch velocity derived from peak height: v = sqrt(2 * g * h)
local jumpVelocity = math.sqrt(2.0 * CONFIG.GRAVITY * CONFIG.JUMP_PEAK_HEIGHT)

-- ─────────────────── wall type mapping ──────────────────────────────
local WALL_HEIGHTS = { [1] = 1, [2] = 2, [3] = 3 }
local MAX_WALL_UNITS = 1
for _, h in pairs(WALL_HEIGHTS) do
  if h > MAX_WALL_UNITS then MAX_WALL_UNITS = h end
end

-- Horizontal traversal crosses at most sqrt(2) grid planes per world-space unit.
local MAX_DDA_STEPS = math.ceil(CONFIG.VIEW_DIST * math.sqrt(2)) + 2

-- ─────────────────── state variables ────────────────────────────────
local SCR_W, SCR_H = 0, 0
local RENDER_W, RENDER_H = 0, 0
local renderCanvas = nil
local px, py, rot, pitch = 3.5, 3.5, 0, 0
local eyeHeight = CONFIG.CAM_HEIGHT
local yVel = 0
local velX, velY = 0, 0
local currentFloor = 0
local physicsAccumulator = 0
local previousPx, previousPy = px, py
local previousEyeHeight = eyeHeight
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
local camForward = { 0, 0, 0 }
local camRight   = { 0, 0, 0 }
local camUp      = { 0, 0, 0 }

-- ─────────────────── textures & level map ───────────────────────────
local dirt = love.graphics.newImage("dirt.png")
dirt:setFilter("nearest", "nearest")
dirt:setWrap("repeat", "repeat")

local grass = love.graphics.newImage("grass.png")
grass:setFilter("nearest", "nearest")
grass:setWrap("repeat", "repeat")

local blinkSkybox = love.graphics.newImage("skybox/blink/cubemap.png")
blinkSkybox:setFilter("linear", "linear")
blinkSkybox:setWrap("clamp", "clamp")
local skyboxFaceSize = blinkSkybox:getWidth() / 4

local function createLevelTexture()
  if type(level) ~= "table" or #level == 0 or type(level[1]) ~= "table" or #level[1] == 0 then
    error("Level must be a non-empty rectangular table")
  end

  local levelW, levelH = #level, #level[1]
  local warnedTypes = {}
  for x = 1, levelW do
    if type(level[x]) ~= "table" or #level[x] ~= levelH then
      error(("Level is not rectangular: column %d has height %d, expected %d")
        :format(x, type(level[x]) == "table" and #level[x] or 0, levelH))
    end
    for y = 1, levelH do
      local wt = level[x][y]
      local warningKey = tostring(wt)
      if wt ~= 0 and WALL_HEIGHTS[wt] == nil and not warnedTypes[warningKey] then
        print(("Warning: undefined wall type %s at level cell (%d, %d); treating it as empty")
          :format(warningKey, x, y))
        warnedTypes[warningKey] = true
      end
    end
  end

  local imageData = love.image.newImageData(levelW, levelH)
  for x = 1, levelW do
    for y = 1, levelH do
      local wt = level[x][y] or 0
      local height = WALL_HEIGHTS[wt] or 0
      imageData:setPixel(x - 1, y - 1, height / MAX_WALL_UNITS, 0, 0, 1)
    end
  end
  local texture = love.graphics.newImage(imageData)
  texture:setFilter("nearest", "nearest")
  texture:setWrap("clamp", "clamp")
  imageData:release()
  return texture, levelW, levelH
end

local levelTexture, levelW, levelH = createLevelTexture()

-- ─────────────────── heightfield DDA shader ─────────────────────────
local raycastShader = love.graphics.newShader([[
extern vec3 camPos;
extern vec3 camForward;
extern vec3 camRight;
extern vec3 camUp;
extern float tanHalfHFOV;
extern float tanHalfVFOV;

extern Image wallTex;
extern Image floorTex;
extern Image levelTex;
extern Image skyboxTex;
extern vec2  levelSize;
extern float maxUnits;
extern float viewDist;
extern float skyboxFaceSize;

vec4 sampleSkybox(vec3 worldDir) {
  // Cubemap axes: +X right, +Y top, +Z front.
  vec3 dir = vec3(worldDir.y, worldDir.z, worldDir.x);
  vec3 ad = abs(dir);
  vec2 faceUV;
  vec2 atlasCell;

  if (ad.x >= ad.y && ad.x >= ad.z) {
    if (dir.x > 0.0) {
      faceUV = vec2(-dir.z, -dir.y) / ad.x;
      atlasCell = vec2(2.0, 1.0); // right
    } else {
      faceUV = vec2(dir.z, -dir.y) / ad.x;
      atlasCell = vec2(0.0, 1.0); // left
    }
  } else if (ad.y >= ad.z) {
    if (dir.y > 0.0) {
      faceUV = vec2(dir.x, dir.z) / ad.y;
      atlasCell = vec2(1.0, 0.0); // top
    } else {
      faceUV = vec2(dir.x, -dir.z) / ad.y;
      atlasCell = vec2(1.0, 2.0); // bottom
    }
  } else {
    if (dir.z > 0.0) {
      faceUV = vec2(dir.x, -dir.y) / ad.z;
      atlasCell = vec2(1.0, 1.0); // front
    } else {
      faceUV = vec2(-dir.x, -dir.y) / ad.z;
      atlasCell = vec2(3.0, 1.0); // back
    }
  }

  faceUV = faceUV * 0.5 + 0.5;
  float inset = 0.5 / skyboxFaceSize;
  faceUV = clamp(faceUV, vec2(inset), vec2(1.0 - inset));
  return Texel(skyboxTex, (atlasCell + faceUV) / vec2(4.0, 3.0));
}

float getCellHeight(vec2 cell) {
  if (cell.x < 0.0 || cell.x >= levelSize.x || cell.y < 0.0 || cell.y >= levelSize.y) {
    return 0.0;
  }
  vec2 uv = (cell + vec2(0.5)) / levelSize;
  return floor(Texel(levelTex, uv).r * maxUnits + 0.5);
}

vec4 effect(vec4 color, Image dummy, vec2 tc, vec2 sc)
{
  vec2 ndc = (sc / love_ScreenSize.xy) * 2.0 - 1.0;
  ndc.y = -ndc.y;

  vec3 rayDir = normalize(camForward +
                          camRight * (ndc.x * tanHalfHFOV) +
                          camUp    * (ndc.y * tanHalfVFOV));

  // Columns are solid below their tops: only XY grid boundaries need DDA.
  if (camPos.z >= maxUnits && rayDir.z >= 0.0) return sampleSkybox(rayDir);

  vec2 mapPos = floor(camPos.xy);
  vec2 deltaDist = 1.0 / max(abs(rayDir.xy), vec2(1e-8));
  vec2 stepDir = sign(rayDir.xy);
  vec2 sideDist = (stepDir * (mapPos - camPos.xy) + stepDir * 0.5 + 0.5) * deltaDist;

  float groundDist = rayDir.z < 0.0 ? -camPos.z / rayDir.z : viewDist + 1.0;
  bool hit = groundDist >= 0.0 && groundDist <= viewDist;
  float hitDist = hit ? groundDist : viewDist;
  bool isFloorGround = hit;
  vec3 mask = vec3(0.0, 0.0, 1.0);
  vec3 entryMask = vec3(0.0);
  float entryDist = 0.0;

  for (int i = 0; i < ]] .. MAX_DDA_STEPS .. [[; ++i) {
    float exitDist = min(sideDist.x, sideDist.y);
    float cellH = getCellHeight(mapPos);
    float entryZ = camPos.z + rayDir.z * entryDist;

    if (cellH > 0.0) {
      // Match voxel face priority when a downward ray meets a top/side edge.
      if (entryMask.x + entryMask.y > 0.0 &&
          (entryZ < cellH || (entryZ == cellH && rayDir.z < 0.0))) {
        hit = true;
        hitDist = entryDist;
        mask = entryMask;
        isFloorGround = false;
        break;
      }
      if (rayDir.z < 0.0) {
        float topDist = (cellH - camPos.z) / rayDir.z;
        if (topDist >= entryDist && topDist <= min(exitDist, hitDist)) {
          hit = true;
          hitDist = topDist;
          mask = vec3(0.0, 0.0, 1.0);
          isFloorGround = false;
          break;
        }
      }
    }

    if (exitDist >= hitDist) break;
    entryDist = exitDist;
    if (sideDist.x < sideDist.y) {
      sideDist.x += deltaDist.x;
      mapPos.x += stepDir.x;
      entryMask = vec3(1.0, 0.0, 0.0);
    } else {
      sideDist.y += deltaDist.y;
      mapPos.y += stepDir.y;
      entryMask = vec3(0.0, 1.0, 0.0);
    }
    if (rayDir.z >= 0.0 && camPos.z + rayDir.z * entryDist >= maxUnits) break;
  }

  if (!hit) {
    return sampleSkybox(rayDir);
  }

  vec3 hitPoint = camPos + rayDir * hitDist;
  vec4 texCol;
  float shade = 1.0;

  if (mask.z > 0.5) {
    vec2 floorUV = fract(hitPoint.xy);
    texCol = Texel(floorTex, floorUV);
    shade = isFloorGround ? 0.75 : 0.95;
  } else {
    vec2 wallUV;
    if (mask.x > 0.5) {
      wallUV = vec2(hitPoint.y, 1.0 - hitPoint.z);
      shade = 0.85;
    } else {
      wallUV = vec2(hitPoint.x, 1.0 - hitPoint.z);
      shade = 0.70;
    }
    texCol = Texel(wallTex, fract(wallUV));
  }

  float fog = clamp(1.0 - (hitDist / viewDist), 0.0, 1.0);
  return vec4(texCol.rgb * shade * fog, 1.0);
}
]])

-- ─────────────────── collision handling ────────────────────────────
local function getHighestFloorUnder(x, y, minHeight, maxHeight)
  local r = CONFIG.PLAYER_RADIUS
  local minX = math.floor(x - r) + 1
  local maxX = math.floor(x + r) + 1
  local minY = math.floor(y - r) + 1
  local maxY = math.floor(y + r) + 1

  minHeight = minHeight or -math.huge
  maxHeight = maxHeight or math.huge
  local maxH = (minHeight <= 0 and maxHeight >= 0) and 0 or nil
  for ix = minX, maxX do
    for iy = minY, maxY do
      if ix >= 1 and ix <= levelW and iy >= 1 and iy <= levelH then
        local wt = level[ix][iy] or 0
        local wh = WALL_HEIGHTS[wt] or 0
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

  for ix = minX, maxX do
    for iy = minY, maxY do
      if ix >= 1 and ix <= levelW and iy >= 1 and iy <= levelH then
        local wt = level[ix][iy] or 0
        local wh = WALL_HEIGHTS[wt] or 0
        -- Airborne players cannot step using the height of their old support.
        local tooHighToStep = not canStep or wh > currentFloor + CONFIG.MAX_STEP_HEIGHT + CONFIG.GROUND_EPS
        if wh > 0 and tooHighToStep and footH < (wh - CONFIG.GROUND_EPS) then
          return true
        end
      end
    end
  end
  return false
end

local function move(dx, dy, canStep)
  if dx == 0 and dy == 0 then return end
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

-- ─────────────────── viewport update ────────────────────────────────
local function updateProjection(w, h)
  SCR_W, SCR_H = w, h
  if type(CONFIG.RENDER_SCALE) ~= "number" or CONFIG.RENDER_SCALE <= 0 or CONFIG.RENDER_SCALE > 1 then
    error("CONFIG.RENDER_SCALE must be greater than 0 and at most 1")
  end
  RENDER_W = math.max(1, math.floor(SCR_W * CONFIG.RENDER_SCALE + 0.5))
  RENDER_H = math.max(1, math.floor(SCR_H * CONFIG.RENDER_SCALE + 0.5))

  if not renderCanvas or renderCanvas:getWidth() ~= RENDER_W or renderCanvas:getHeight() ~= RENDER_H then
    if renderCanvas then renderCanvas:release() end
    renderCanvas = love.graphics.newCanvas(RENDER_W, RENDER_H, { msaa = 0, dpiscale = 1 })
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
  local dw, dh = love.window.getDesktopDimensions()
  love.window.setMode(dw, dh, {
    fullscreen = true,
    fullscreentype = "desktop",
    vsync = CONFIG.VSYNC and 1 or 0,
    msaa = 0
  })
  love.mouse.setRelativeMode(true)
  love.graphics.setBackgroundColor(0, 0, 0)

  updateProjection(love.graphics.getDimensions())

  -- Static uniform binding
  raycastShader:send("wallTex", dirt)
  raycastShader:send("floorTex", grass)
  raycastShader:send("levelTex", levelTexture)
  raycastShader:send("skyboxTex", blinkSkybox)
  raycastShader:send("levelSize", { levelW, levelH })
  raycastShader:send("maxUnits", MAX_WALL_UNITS)
  raycastShader:send("viewDist", CONFIG.VIEW_DIST)
  raycastShader:send("skyboxFaceSize", skyboxFaceSize)
end

function love.mousemoved(_, _, dx, dy)
  rot = (rot + dx * 0.002) % (2 * math.pi)
  pitch = math.max(-CONFIG.MAX_PITCH, math.min(CONFIG.MAX_PITCH, pitch - dy * 0.002))
end

local function updatePhysics(dt)
  -- Resolve walkable support without considering taller neighboring walls.
  local footHeight = eyeHeight - CONFIG.CAM_HEIGHT
  local grounded = math.abs(footHeight - currentFloor) <= CONFIG.GROUND_EPS and yVel <= 0
  local walkableFloor = getHighestFloorUnder(
    px, py, -math.huge, currentFloor + CONFIG.MAX_STEP_HEIGHT
  ) or 0

  if grounded and walkableFloor > currentFloor + CONFIG.GROUND_EPS then
    currentFloor = walkableFloor
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
  local targetSpeed = (grounded and shift) and CONFIG.SPRINT_SPEED or CONFIG.MOVE_SPEED
  local currentAccel = grounded and CONFIG.ACCEL_GROUND or CONFIG.ACCEL_AIR
  local currentDrag  = grounded and CONFIG.FRICTION or CONFIG.AIR_DRAG

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

  -- Recheck support only after movement changes the player footprint.
  if grounded and (px ~= oldPx or py ~= oldPy) then
    walkableFloor = getHighestFloorUnder(
      px, py, -math.huge, currentFloor + CONFIG.MAX_STEP_HEIGHT
    ) or 0
    if walkableFloor > currentFloor + CONFIG.GROUND_EPS then
      currentFloor = walkableFloor
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
  hudElapsed = hudElapsed + dt
  updatePerformanceStats(dt)
  physicsAccumulator = physicsAccumulator + math.min(dt, CONFIG.MAX_FRAME_DT)

  while physicsAccumulator >= CONFIG.FIXED_DT do
    previousPx, previousPy = px, py
    previousEyeHeight = eyeHeight
    updatePhysics(CONFIG.FIXED_DT)
    physicsAccumulator = physicsAccumulator - CONFIG.FIXED_DT
  end

  if love.keyboard.isDown("escape") then
    love.event.quit()
  end
end

function love.draw()
  local interpolationAlpha = physicsAccumulator / CONFIG.FIXED_DT
  local renderPx = previousPx + (px - previousPx) * interpolationAlpha
  local renderPy = previousPy + (py - previousPy) * interpolationAlpha
  local renderEyeHeight = previousEyeHeight +
                          (eyeHeight - previousEyeHeight) * interpolationAlpha
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

  if camPos[1] ~= renderPx or camPos[2] ~= renderPy or camPos[3] ~= renderEyeHeight then
    camPos[1], camPos[2], camPos[3] = renderPx, renderPy, renderEyeHeight
    raycastShader:send("camPos", camPos)
  end

  love.graphics.setCanvas(renderCanvas)
  love.graphics.setBlendMode("replace") -- Full-screen shader overwrites every pixel.
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setShader(raycastShader)
  love.graphics.rectangle("fill", 0, 0, RENDER_W, RENDER_H)
  love.graphics.setShader()
  love.graphics.setCanvas()

  love.graphics.draw(renderCanvas, 0, 0, 0, SCR_W / RENDER_W, SCR_H / RENDER_H)

  love.graphics.setBlendMode("alpha")

  -- Rebuild text at 10 Hz instead of formatting and laying it out every frame.
  if hudElapsed >= 0.1 then
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
    hud:add(("RAM: %.1f MB | Graphics memory: %.1f MB"):format(
      performance.ramMB, performance.graphicsMemoryMB
    ), 0, 60)
    hud:add(("Eye Z: %.2f (Peak Jump: +%.2f)"):format(
      eyeHeight, CONFIG.JUMP_PEAK_HEIGHT
    ), 0, 80)
    hud:add(("Speed: %.2f"):format(
      math.sqrt(velX * velX + velY * velY)
    ), 0, 100)
  end
  love.graphics.draw(hud, 10, 10)
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
