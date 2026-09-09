-- Run from project root: luajit tools/check_frame_loop.lua
local file = assert(io.open("main.lua", "r"))
local source = file:read("*a")
file:close()
local runSource = assert(source:match("function love.run%(%)%s*.*"))
local makeRun = assert(loadstring("return function(CONFIG, love)\n" .. runSource .. "\nreturn love.run end"))()

local function setup(limit, vsync, work, focused, active, oversleep, truncateSleep)
  local now, previous, sleeps, updates = 0, 0, {}, {}
  local events, handled = {}, 0
  local love = {
    arg = { parseGameArguments = function() return {} end },
    timer = {
      step = function() local dt = now - previous; previous = now; return dt end,
      getTime = function() return now end,
      sleep = function(t)
        assert(t > 0)
        sleeps[#sleeps + 1] = t
        now = now + (truncateSleep and math.floor(t * 1000) / 1000 or t) + (oversleep or 0)
      end,
    },
    event = {
      pump = function() end,
      poll = function()
        local pending = events
        events = {}
        local i = 0
        return function() i = i + 1; if pending[i] then return unpack(pending[i]) end end
      end,
    },
    handlers = { keypressed = function() handled = handled + 1 end },
    update = function(dt) updates[#updates + 1] = dt; now = now + work end,
    draw = function() end,
    graphics = { isActive = function() return active ~= false end,
      origin = function() end, present = function() end },
    window = { hasFocus = function() return focused ~= false end },
  }
  local tick = makeRun({ MAX_FPS = limit, VSYNC = vsync }, love)()
  return tick, sleeps, updates, function(event) events[#events + 1] = event end,
    love, function() return now, handled end
end

local function near(a, b) assert(math.abs(a - b) < 1e-10, tostring(a) .. " ~= " .. tostring(b)) end
for _, fps in ipairs({30, 60, 144, 240, 333}) do
  local tick, sleeps, updates = setup(fps, false, 0.001)
  tick(); tick()
  near(sleeps[1], 1 / fps - 0.001)
  near(updates[2], 1 / fps)
end
for _, mode in ipairs({{0, false}, {144, true}}) do
  local tick, sleeps = setup(mode[1], mode[2], 0.002)
  tick(); assert(#sleeps == 0, "Uncapped/VSync mode must not sleep")
end
local tick, sleeps = setup(144, false, 0.02)
tick(); tick(); assert(#sleeps == 0, "Over-budget frames must not sleep")
for _, mode in ipairs({{false, true}, {true, false}}) do
  tick, sleeps = setup(0, false, 0.001, mode[1], mode[2])
  tick(); near(sleeps[1], 0.01)
end
tick, sleeps = setup(30, false, 0.001, false)
tick(); near(sleeps[1], 1 / 30 - 0.001) -- Background delay is not added twice.
local updates
tick, sleeps, updates = setup(60, false, 0.001, true, true, 0.003)
tick(); tick(); near(updates[2], 1 / 60 + 0.003)
near(sleeps[2], 1 / 60 - 0.001 - 0.003) -- Recover sleep overshoot next frame.
local enqueue, love, state
tick, sleeps, updates, enqueue, love, state = setup(60, false, 0.001)
enqueue({"keypressed", "w"}); tick(); local _, handled = state(); assert(handled == 1)
love.quit = function() return true end
enqueue({"quit", 7}); assert(tick() == nil, "Quit veto ignored")
love.quit = function() return false end
enqueue({"quit", 7}); assert(tick() == 7, "Quit status lost")
tick, sleeps, updates, enqueue, love, state = setup(144, false, 0.001, true, true, 0, true)
tick(); local elapsed = state()
assert(elapsed >= 1 / 144 and elapsed < 1 / 144 + 0.001, "Truncated sleep exceeded FPS limit")
assert(#sleeps == 2 and sleeps[2] >= 0.001, "Short sleep must yield, not spin")
-- Fractional-millisecond truncation and oversleep must not reduce average FPS.
for _, fps in ipairs({144, 333}) do
  tick, sleeps, updates, enqueue, love, state = setup(fps, false, 0.0001, true, true, 0.0002, true)
  for i = 1, 1000 do tick() end
  local elapsed = state()
  assert(math.abs(1000 / elapsed - fps) < 0.2, "Frame schedule accumulated sleep drift")
end
-- A one-second stall must not leave a backlog of deadlines to catch up.
tick, sleeps, updates, enqueue, love, state = setup(333, false, 0.0001)
tick()
love.timer.sleep(1)
local sleepCount = #sleeps
tick()
near(sleeps[sleepCount + 1], 1 / 333 - 0.0001)
for _, value in ipairs({-1, math.huge, 0/0, "144"}) do
  assert(not pcall(setup, value, false, 0), "Invalid FPS accepted")
end
print("PASS: 30/60/144/240/333 FPS, uncapped, VSync, overload, background, oversleep, truncated sleep, average rate, stall recovery, events, quit, validation")
