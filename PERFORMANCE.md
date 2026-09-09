Performance review — 2026-09-09

Screenshot: 848 FPS, 1.18 ms/frame, 11.7% process CPU, 39% device GPU.
Installed LÖVE 11.5 default loop requests 1 ms sleep every frame, including
VSync-off mode. Sleep explains much of frame interval; screenshot does not
establish GPU saturation. CPU counter measures process CPU time against wall
time, not whole-machine utilization. GPU counter covers whole device.

Changes completed:

- XY DDA traverses solid heightfield columns; floor and top intersections use
  direct plane calculations. Maximum traversal iterations drop from 51 to 25.
  Rays above tallest wall and pointing upward exit early.
- True perspective pitch, view distance, textures, fog, and render scale retained.
- Active frame loop removes unconditional 1 ms sleep. VSync still governs
  presentation when enabled; inactive/unfocused window yields for 10 ms.
  Initial validation used VSync enabled; current pacing settings appear below.
  Uncapped mode can consume more power.
- Camera uniforms update only when position or orientation changes.
- HUD text rebuilds at 10 Hz and draws from cached Text object.
- Full-screen passes overwrite pixels directly; redundant clears removed.
- Linear drag uses equivalent scalar multiplier. Stationary movement skips
  collision work. Resizing explicitly releases previous canvas.

Measured on RX 6700 XT, Mesa 26.2.2, LÖVE 11.5, at 960×540 internal resolution:

| Warmed render throughput | Before | After |
| --- | ---: | ---: |
| Mean of twelve camera-case medians | 0.0693 ms | 0.0467 ms |
| Upward view, pitch +60° | 0.121 ms | 0.049 ms |
| Upward view, pitch +89.5° | 0.124 ms | 0.042 ms |

Overall render cost fell about 33% in this run. Each case warms up for 100
renders, then measures five batches of 300 draws, synchronizing through canvas
readback. These measurements include draw submission and amortized readback;
they exclude normal update loop, sleep, and desktop presentation. GPU clocks
and workload affect results. They are not predictions of desktop FPS.

Validation completed:

- Lua bytecode and actual GPU shader compilation passed.
- Twelve benchmark images passed comparison, including exact top/side edges.
- Expanded 92-view comparison covered 47,692,800 pixels: 46 pixels differed by
  more than 3/255 in a color channel. Differences occur at texture sampling
  boundaries; output is not claimed to be bit-identical.
- 2,400-step movement comparison: maximum state difference approximately 1e-13.
- Jumping, landing on 1/2/3-unit columns, ±89.5° pitch limits, odd viewport
  dimensions, repeated resize memory checks, and event-driven exit passed.
- User confirmed improved gameplay responsiveness.

Graphics memory: 4096×3072 RGBA skybox atlas occupies 48 MiB. Wall/floor textures
add 0.266 MiB; 960×540 canvas adds 1.978 MiB. This accounts for reported 50.2 MiB
without reducing texture quality.

Run repeatable benchmark from project directory:

```sh
python3 tools/benchmark.py
python3 tools/benchmark.py --baseline /path/to/previous/main.lua
```

Benchmark uses current assets for both versions, creates isolated temporary
LÖVE projects, and writes timing logs plus PNGs. Optional `--output` sets artifact
directory. Reference comparison fails when more than 0.01% of pixels differ by
more than 3/255; small tolerance permits nearest-neighbor rounding differences.

Follow-up review and frame limiter

Current settings in main.lua:

```lua
VSYNC   = false,
MAX_FPS = 333,   -- 0 = uncapped; ignored when VSYNC is true
```

Limiter advances a shared deadline by one frame interval, then sleeps only
for remaining time after event/update/draw/presentation work. Sleep overshoot
shortens the next wait, keeping average FPS on target. Deadlines rebase after
a full missed interval, preventing long stalls from causing catch-up bursts.
Individual frame intervals can vary around target interval. Sleeping avoids
CPU spinning. Deadline is rechecked after each sleep, since SDL can truncate
fractional milliseconds; residual waits sleep at least 1 ms. OS scheduling can
produce actual FPS slightly below requested cap.
Unfocused/minimized windows retain at least 10 ms sleep without stacking delays.
Settings are read when game starts; restart after editing configuration.

Additional cleanup avoids repeat support queries when movement leaves position
unchanged, reuses canvas when internal dimensions stay unchanged, scopes projection
variables locally, and removes redundant color-state call. Twelve before/after
images are bit-identical; 2,400-step physics states match exactly. Render timing
remains in previous range; no additional FPS gain is claimed from this cleanup.

Remaining optimization candidates:

- Native six-face cubemap could reduce skybox allocation from 48 to 24 MiB and
  replace manual face-selection shader code. Requires orientation/seam validation
  and separate timing; no measured FPS benefit established.
- Hierarchical empty-space skipping targets larger maps. Current 12×12 map and
  16-unit view distance offer little justification for extra traversal machinery.
- Lower internal resolution reduces pixel work but changes image quality.

Current review found no further demonstrated major bottleneck warranting another
renderer redesign. These candidates remain opportunities, not claims of optimality.

Limiter regression check:

```sh
luajit tools/check_frame_loop.lua
```

Virtual-clock checks cover 30/60/144/240/333 FPS, uncapped mode, VSync precedence,
over-budget frames, background throttling, oversleep, truncated sleeps, event
dispatch, quit veto,
exit status, and invalid configuration. Rendering benchmark deliberately bypasses
frame pacing so capped FPS cannot hide renderer regressions.

Historical test before deadline-drift fix: offscreen frame loop at
1920×1080, 960×540 internal resolution,
144 FPS cap: 1,000 measured frames after 200 warmup frames averaged 7.238 ms
(~138 FPS), median 7.173 ms. Sleep granularity accounts for undershoot; deadline
rechecks prevent truncated sleeps from exceeding configured limit. Desktop
presentation and system load can change achieved rate.

Frame-pacing drift fix

Previous limiter reset deadline from actual start every frame. Timer overshoot
therefore accumulated, turning a 333 FPS setting into roughly 311 FPS in user
measurement. Shared deadlines now compensate normal sleep jitter. VSync,
uncapped mode, and background yielding retain their existing behavior.
Regression tests also check average rate over 1,000 simulated frames with
truncated sleeps and overshoot, plus recovery after a one-second stall.

Post-fix real offscreen test, same 1920×1080 output and 960×540 internal size:
1,000 measured frames after 200 warmup frames averaged 3.003 ms, matching
333 FPS. Median interval was 3.156 ms, p95 3.362 ms; jitter is absorbed across
frames rather than added permanently to every frame budget.
