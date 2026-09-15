# World Generation V2 — Part 2

Measured 2026-09-12 on Ryzen 5 5600X / Radeon RX 6700 XT, LÖVE 11.5,
LuaJIT, OpenGL 4.6, Mesa 26.2.2. Seed 1337, 256-block game view distance,
1,225 resident chunks. Part 1 source was saved and measured before modification
in `tools/baselines/part1/`. Final comparable profiles use the same harness and
18,000 simulated frames, including movement into previously uncached macro regions.

## Feature profiles

Raw CSVs live in `artifacts/surface-v2/profile-*.csv`.

| Metric | Part 1 | Geography | + Mountains | + Rivers | + Materials (full) |
| --- | ---: | ---: | ---: | ---: | ---: |
| Generation/chunk median, µs | 3.34 | 6.82 | 6.76 | 6.98 | 7.05 |
| Generation/chunk p99, µs | 6.06 | 7.33 | 10.17 | 10.23 | 21.18 |
| Initial cache fill, ms | 16.65 | 53.65 | 70.19 | 85.74 | 86.29 |
| Streaming/frame p99, ms | 0.02595 | 0.04705 | 0.05347 | 0.03881 | 0.03902 |
| Streaming/frame maximum, ms | 0.171 | 1.818 | 2.191 | 0.874 | 0.880 |
| Macro build mean, ms | — | 4.60 | 10.21 | 13.99 | 13.75 |
| Macro build maximum, ms | — | 6.48 | 14.87 | 18.74 | 18.15 |
| Macro cache/scratch, MiB | — | 9.58 | 9.58 | 9.58 | 9.58 |
| Upload median, µs | 5.29 | 5.46 | 5.48 | 5.56 | 5.51 |
| Queue update median, µs | 3.63 | 3.82 | 3.52 | 3.73 | 3.80 |

The complete surface costs roughly twice Part 1's warm generation time, while
upload/queue medians remain within about 5%. This includes water and material
classification. Cached macro work keeps warm river/mountain overhead small.
Initial loading is intentionally more expensive. These are separate runs; tail
samples include scheduling and JIT effects, so non-monotonic p99/max values do
not establish that enabling a feature makes it faster.

Generation loops reuse all block storage. Full warm allocation probe measured
0 KiB heap growth across 4,000 chunks. Queue probe measured 0.44 KiB across
1,000 updates, including LuaJIT bookkeeping. Cold macro builds allocate coroutine
state outside chunk loops; macro height, routing, accumulation and raster arrays
are preallocated. The fixed nine-region cache plus scratch arrays occupies
9,804.94 KiB. Full cache-associated Lua/FFI heap measured about 11.98 MiB.

Terrain height payload remains 612.5 KiB. Packed surface payload adds 612.5 KiB.
The combined `rg16f` GPU image and its CPU reload mirror are each 1,225 KiB.
Compared with Part 1, the added channel avoids another texture, another upload
call, and another per-ray lookup. Heights, material IDs and water levels remain
exact in half precision. Maximum images remain about 2.4 KiB each.

## Reproduction and scope

```sh
python3 tools/profile_world.py --world tools/baselines/part1/world.lua --terrain tools/baselines/part1/terrain.lua
python3 tools/profile_world.py --stage geography
python3 tools/profile_world.py --stage mountains
python3 tools/profile_world.py --stage rivers
python3 tools/profile_world.py --stage full
```

Run sequentially; `--output path.csv` records measurements. Warm generation uses
4,000 chunk operations. Upload timing covers encoding, reload-image maintenance,
height/surface upload, and maximum upload; it measures CPU API submission, not
GPU completion. Queue stress uses 1,000 diagonal boundary crossings with unfinished
requests. Allocation probes use separate warmed batches with GC stopped.

Streaming simulates 18,000 updates at 60 Hz, moving 5 and 3 blocks/second along
X/Y: seven macro regions are built in the Part 2 runs. Macro timings sum active
coroutine CPU time, excluding suspension between frames. Generation/frame timing
includes macro advancement but excludes wrapped GPU upload calls.

Streaming checks a 0.75 ms deadline between chunks/batches, at most two chunk
uploads per update, and approximately 0.2 ms macro advances. It is a cooperative
budget, not a hard real-time limit: JIT compilation, scheduling, or one resume
can finish beyond it. The full profile's maximum update was 0.880 ms; separate
render checks observed about 1 ms. Initial loading completes required regions
synchronously. Macro cache hits do not rebuild regional data.

## Optimizations verified during implementation

An initial monolithic interpolation/classification loop triggered LuaJIT register
coalescing failures and measured roughly 63 µs/chunk. Separate reused interpolation
passes reduced it to roughly 9 µs. Reusing four-pixel interpolation increments
brought warm generation to roughly 7 µs before retaining the added features.

Jittered global drainage nodes and bent edges removed obvious parallel/grid-aligned
river artifacts from the first atlas. They retain strict downhill routing and
exact halo agreement. Accumulation is capped at 32 cells: this permits an exact,
finite dependency halo rather than heuristic regional boundary inflow. River
width/depth saturate with that cap. Local drainage sinks form lakes; this phase
does not simulate unlimited catchments or full hydraulic erosion.

## Rendering and visual validation

At native 1920×1080, 1,200 moving frames after 60 warmup frames measured:

| Full surface rendering + GPU readback | Time |
| --- | ---: |
| Median | 2.301 ms |
| p99 | 8.893 ms |
| Maximum | 11.556 ms |
| Streaming p99 during rendering | 0.102 ms |

Presentation and frame pacing are excluded. Incremental ray stepping measured
2.247 ms median on the same surface but produced edge-pixel disagreements.
Analytic crossings cost about 2.4% in these separate runs and produce exact
accelerated/unaccelerated framebuffer agreement across all 15 tested views.

The reproducible random-seed survey covers three 4096×4096-block areas. Maps with
small detail disabled preserve coastlines, plains, mountain networks and rivers.
Nine actual flying-view screenshots show peaks, coastlines and river valleys at
768-block QA view distance. See `artifacts/surface-v2/atlas.png`, `flight-views.png`
and `survey.json` for seeds, positions and material/water coverage.

Tests verify wet river centerlines, downhill and monotone capped flow, confluences,
ocean/lake outlets, exact shared regional controls in positive and negative
coordinates, macro scheduling/order independence, chunk/scalar agreement,
cache eviction, fixed buffer reuse, beach slope/width, cliff exclusion, snow and
rock, collision/flight, display reloads, full visible residency, and packed GPU
round trips for every supported material/water code. No caves or overhangs added.


## Part 2.5 — level water bodies

`artifacts/surface-v2/profile-before-water.csv` preserves the Part 2 baseline;
`profile-water.csv` records the final water changes with the same sequential harness.

| Metric | Before water fix | Level water |
| --- | ---: | ---: |
| Chunk median, µs | 7.05 | 7.53 |
| Chunk p99, µs | 21.18 | 15.48 |
| Streaming p99, ms | 0.0390 | 0.0418 |
| Streaming maximum, ms | 0.880 | 0.949 |
| Initial fill, ms | 86.29 | 104.18 |
| Macro mean / maximum, ms | 13.75 / 18.15 | 16.40 / 25.17 |
| Upload median, µs | 5.51 | 5.54 |
| Queue median, µs | 3.80 | 3.59 |

Warm chunk cost increased about 7%; fixed regional arrays and packed GPU storage
remain unchanged. Destination tracing adds temporary macro-build memo tables, then
releases them. Full cache-associated heap measured 12.45 MiB. The warm 4,000-chunk
allocation probe grew 0.81 KiB including JIT bookkeeping; no per-block objects were
added. Destination work yields between path nodes and shares the streaming budget.
Its path length is not artificially bounded at the halo, so cold costs depend on
catchment size. The fixed 9.58 MiB regional array figure excludes this temporary memo.

Water levels no longer interpolate along paths or across four-block controls.
Ocean destinations use sea level; inland sinks share their lowest D8 spill rim;
higher inland reaches use 24-block elevation bands and explicit drops. Bed profiles
remain smooth and independent. Water levels override the ocean fallback for inland
beds below sea level. The shader intersects both sides of vertical water transitions,
water tops, and submerged terrain using the existing two-channel image.

`check_water.lua` tests a synthetic ocean path longer than the old halo, six real
seeds, shared basin levels, downhill reach transitions, and every adjacent wet
column in six 1024×1024 areas. All 64 differing-level edges have unobstructed water
faces. Controlled GPU scenes test top/bed ordering and waterfall entry/exit faces;
existing deterministic, regional-seam and accelerated-ray comparisons still apply.
Refreshed atlas and flying previews show the corrected water bodies. Local D8 sink
spill estimates remain a coarse basin model, not a full flood-fill erosion simulation.

Final native 1920×1080 rendering plus readback measured 2.689 ms median,
8.044 ms p99, and 11.130 ms maximum over 1,200 moving frames. Vertical water-volume
intersection handling raises median rendering cost from Part 2's 2.301 ms by about
17% in these separate runs. Streaming during this render run measured 0.138 ms p99.
Raw output: `artifacts/surface-v2/profile-water-render.txt`.

A min/max rewrite of the waterfall interval test measured 4.338 ms median rendering
and was rejected; the measured and GPU-tested branch expression was restored.


## Part 2.6 — banks and generated flow

Same machine, seed, view distance and native 1920×1080 moving-frame harness.
Baseline captured before edits in `artifacts/part2-6-before/`; final measurements
in `artifacts/part2-6-final/`. Readback/scheduling remain included; presentation
and frame pacing remain excluded.

| Metric | Before | Part 2.6 |
| --- | ---: | ---: |
| Native render + readback median, ms | 2.327 | 2.873 |
| Native render + readback p99, ms | 3.147 | 6.676 |
| Native render + readback maximum, ms | 9.392 | 8.309 |
| Warm chunk median, µs | 7.68 | 8.82 |
| Warm chunk p99, µs | 12.35 | 21.35 |
| Initial fill, ms | 93.20 | 132.59 |
| Macro mean / maximum, ms | 14.88 / 20.73 | 19.83 / 37.46 |
| Streaming p99 / maximum, ms | 0.0386 / 0.8285 | 0.0749 / 0.8446 |
| Upload median, µs | 5.62 | 5.68 |
| Fixed macro array payload, KiB | 9,804.94 | 10,997.44 |
| Cache-associated Lua/FFI heap, KiB | 12,544.51 | 15,270.32 |
| Warm 4,000-chunk heap growth, KiB | 0.81 | 0.69 |

Native median increased 23.5%; p99 also regressed in these separate runs. This is
not a performance-neutral change. To isolate slope sampling from changed banks,
a flat-top reference with the same final world and packing measured 2.733 ms
median / 6.455 ms p99 (`artifacts/part2-6-flat-reference/`). Enabling corner sampling
and triangles added 0.140 ms median (5.1%) against that reference. Tail differences
between the initial and later runs cannot be assigned entirely to slope sampling.

The water-focused harness compares flat and sloped shaders on identical generated
fall, landing and overview views; its raw results and PNGs are in
`artifacts/part2-6-flow/`. It also requires exact pixel agreement between accelerated
and unaccelerated sloped rays. Initial unconditional slope-edge evaluation was
removed from dry traversal. Full/ocean surfaces take the flat path; fractional
surfaces sample eight neighbors only when the ray reaches their height interval.

GPU height/surface texture remains 1,225 KiB: no extra texture or upload. CPU
integer collision buffers remain 612.5 KiB. Macro arrays grow for the 32-block
geometry margin; sparse flow/bank records account for additional heap outside
those arrays. Cold macro floods allocate temporary work lists; warm chunk loops
allocate no per-column objects. The small measured warm heap growth is LuaJIT
bookkeeping, comparable to the baseline probe.

Validation covers six million-column inland shoreline scans, all seven flow
states, continuous falling columns, bounded lateral spread, downward escape,
a synthetic waterfall exactly on a region boundary, bulk/scalar agreement around
real drops, unchanged drainage tests, GPU half-float round trips, both sloped
triangles and shared corners, collision, and native rendering. Tall neighboring
water faces in the surveyed regions are confined to narrow drop lips. Ocean-only
seed 42 retains its sea-level surface; sea carving and coastal material rules
remain on their existing branches. Previews use the reproducible generated drop
in seed 1337.

Reproduce sequentially:

```sh
python3 tools/benchmark.py --output artifacts/part2-6-final
python3 tools/profile_world.py --output artifacts/part2-6-final/generation.csv
python3 tools/check_flow_render.py
luajit tools/check_flow.lua
luajit tools/check_water.lua
luajit tools/check_surface.lua
python3 tools/check_render.py
```

## Part 2.7 — support-driven outlets and consistent water color

Before sources and timings are preserved in `artifacts/part2-7-before/`.
Final native timings: `artifacts/part2-7-after/render-final/after/timings.txt`;
generation profile: `artifacts/part2-7-after/generation.csv`.
Same machine, seed 1337, 1920×1080, 1,200 moving frames after warmup, GPU readback
included, presentation excluded. Runs were sequential.

| Metric | Part 2.6 baseline | Part 2.7 |
| --- | ---: | ---: |
| Native render median / p99, ms | 2.368 / 3.220 | 2.371 / 3.279 |
| Native render maximum, ms | 3.616 | 3.811 |
| Warm chunk median / p99, µs | 8.86 / 16.67 | 7.54 / 10.32 |
| Initial fill, ms | 127.62 | 137.71 |
| Macro mean / maximum, ms | 19.29 / 36.66 | 21.83 / 39.59 |
| Streaming p99 / maximum, ms | 0.0656 / 0.9645 | 0.0362 / 0.8394 |
| Upload median, µs | 5.69 | 5.65 |
| Cache-associated Lua/FFI heap, KiB | 15,255.15 | 15,475.82 |
| Warm 4,000-chunk heap growth, KiB | 0.69 | 0.22 |

Native median rose 0.1%; p99 rose 1.8% in these separate runs. Warm chunk median
fell 14.9% after indexing sparse records by chunk. Cold support/outlet detection
adds work and cached records; fixed macro arrays and the 1,225 KiB `rg16f` texture
are unchanged. No per-column objects or per-frame fluid simulation were added.
The small warm allocation probe growth includes LuaJIT bookkeeping.

Support checks run for every hydrology path, independently of reach-level equality.
Sink records retain the existing lowest D8 rim; only its outward downhill outlet
generates spill geometry. These additions do not change receivers, accumulation,
or basin levels. A one-block drop uses seven fractional states and the next full
surface. Larger drops produce narrow columns and landing flow. Secondary falls
restart flow attenuation while retaining a fourteen-step total travel bound.
Incoming horizontal flow merges into existing lakes without raising their level.

Water tops and vertical faces now share RGB `(0.16, 0.51, 0.57)`. Bed depth and fall
height have no color effect. Corner-height sampling and two-triangle intersections
remain restricted to encountered fractional water. GPU tests verify both triangles,
full-height edges, and unchanged accelerated/unaccelerated results.

Acceptance coverage:

| Case | Verification |
| --- | --- |
| 40-block cliff, identical metadata | Production detector emits a falling column; upper/downstream metadata both 72 |
| Lake outlet over cliff | Lowest-rim outlet selection, narrow spill, preserved lake interior |
| One-block drop | FLOW_1..7 ramp, no FALLING state |
| 20-block drop | Continuous column and a lateral landing fan |
| Chunk boundary | Exact bulk/scalar geometry through x=16; continuous 48-block feeder approach |
| Macro boundary | Exact overlapping geometry and translated framebuffer at x=1024 |
| Deep/shallow pools | Identical rendered surface RGB |
| Short/tall falls | Identical RGB for 8- and 80-block faces |
| Determinism/order | Independent rebuilds, reordered real macro generation, existing world/seam tests |

Fixtures and visual checks are implemented in `tools/check_waterfalls.lua` and
`tools/check_waterfall_render.py`; PNGs and assertions are in
`artifacts/part2-7-views/`. The shoreline scan now covers nine 1024×1024 regions,
including real equal-metadata lake outlets in seeds 5, 26 and 33. Existing collision,
packed GPU round trips, drainage, cache eviction and buffer reuse checks pass.

Seed 33 has a real outlet at `(2,168)`: metadata remains 76/76 while rendered water
falls from 76 to 63. Its fall, landing and overview screenshots are in
`artifacts/part2-7-natural/`. All three match unaccelerated sloped rays exactly.
Same-scene flat/sloped median timings were 2.477/2.512 ms (fall), 1.580/1.648 ms
(landing), and 1.875/1.944 ms (overview); raw p99 values accompany the screenshots.

```sh
luajit tools/check_waterfalls.lua
luajit tools/check_water.lua
python3 tools/check_waterfall_render.py
python3 tools/check_flow_render.py --seed 33 --support-only --output artifacts/part2-7-natural
python3 tools/benchmark.py --output artifacts/part2-7-after/render-final
python3 tools/profile_world.py --output artifacts/part2-7-after/generation.csv
```
## Part 2.8 — curved channels and cliff-backed waterfall sheets

Measured at native 1920×1080 on the same RX 6700 XT / Mesa 26.2.2 setup,
1,200 moving frames including render readback. Baseline modules were saved before
editing in `artifacts/part2-8-before/`. Final measurements:

| Metric | Before 2.8 | Part 2.8 |
| --- | ---: | ---: |
| Native render median | 2.367 ms | 2.314 ms |
| Native render p99 | 3.144 ms | 2.980 ms |
| Native streaming p99 | 0.110 ms | 0.099 ms |
| Warm chunk median | 7.26 µs | 7.24 µs |
| Warm chunk p99 | 10.71 µs | 12.46 µs |
| Cached macro build mean / max | 21.84 / 41.51 ms | 43.86 / 75.18 ms |
| Initial graphics/world load | 139.62 ms | 250.24 ms |
| CPU profile streaming p99 / max | 0.0356 / 0.9304 ms | 0.5698 / 0.9440 ms |
| Resident Lua/FFI cache after initial load | 15,375 KiB | 18,689 KiB |
| Warm generation allocation, 4,000 chunks | 0.219 KiB | 0 KiB |
| Height/material/water GPU image | 1,225 KiB | 1,225 KiB |

An earlier 2.8 render run measured 2.434 / 3.287 ms median/p99. Treat the small
render differences as run variation, not evidence of a speedup. The shader is
unchanged; water-only neighbor sampling still occurs only for encountered
fractional surfaces. Geometry changes affect how much flowing water a view sees.
Cached generation is measurably more expensive: curve-distance rasterization,
shared tangent discovery and broader connected fall/shoreline stencils roughly
double macro build time. This work remains resumable and runs once per cache miss;
the measured streaming maximum stays below 1 ms in the CPU profile. Cold load and
retained curve/sparse-record memory are the principal tradeoffs.

`river_geometry.lua` samples Hermite curves about every 2.5 blocks, with shared
drainage tangents and modest world-noise displacement. Quantized binary sub-block
samples and stable voxel rounding prevent diagonal lip differences after region
translation. Lake carving, support detection and fluid lake membership share one
rotated, noise-warped shoreline distance function. Receivers, accumulation and
basin resolution are unchanged; pre-edit regression hashes match for six seeds.
Ocean/beach fields with river geometry disabled also match their pre-edit hashes.

Ordinary channels retain their wet beds when neighboring bank profiles overlap.
Centers deepen smoothly, and a four-block inland safety band keeps shoulders one
block above water. The existing sea-level carving and beach rules stay separate.
Falls use flow-scaled 2–8-column lips (the current accumulation cap reaches six).
Each lane preserves its backing cliff, connects through shallow D4 lip records,
and seeds the existing bounded landing spread. Falling records never lower beds.
No full-resolution texture, dense 3D fluid grid or per-frame simulation was added.

Validation passed:

- Nine CPU suites, including exact region controls/order, chunk/scalar output,
  topology, shorelines, collision, streaming buffers and frame-loop checks.
- Width fixtures at 2/4/6/8 columns, 40-block support loss with identical metadata,
  lake-only outlets, one-block ramps, 20-block falls, and cardinal/diagonal/oblique
  cliffs crossing chunks and macro regions.
- Occupancy floods connect feeder to every tested primary falling lane and its
  landing, with intact solid backing; nine natural falls across six seeds pass.
- 261 ordinary channel centers have at least two blocks depth; 389 dry shoulder
  samples sit at least one block above water. 1,017 edges show curvature, sampled
  segments stay below 4.5 blocks, and consecutive edges share endpoint tangents.
- GPU packing, fractional triangles, full-height edges, water colors and chunk
  skipping remain exact. Controlled broad/small falls and natural flying views
  match unaccelerated rays pixel-for-pixel.

Artifacts: `artifacts/part2-8-views/` contains CPU logs, generation metrics and
controlled/flying screenshots; `artifacts/part2-8-natural/` contains the generated
seed-33 fall, landing and overview with flat/sloped water-view timings.
Native runs are in `artifacts/part2-8-render/` and `artifacts/part2-8-render-final/`.

```sh
luajit tools/check_river_geometry.lua
luajit tools/check_topology.lua
python3 tools/check_waterfall_render.py
python3 tools/check_flow_render.py --seed 33 --support-only --output artifacts/part2-8-natural
python3 tools/profile_world.py --sources artifacts/part2-8-before
python3 tools/profile_world.py
python3 tools/benchmark.py
```

## Part 2.9 — broad mountain profiles and irregular material boundaries

Same generation harness, seed 1337, 256-block view, 18,000 streaming frames.
Sources and baseline CSV: `artifacts/part2-9-before/`. Final CSV and focused
check log: `artifacts/part2-9/`. Before/after runs were sequential.

| Metric | Part 2.8 baseline | Part 2.9 |
| --- | ---: | ---: |
| Warm chunk median / p99, µs | 7.38 / 10.15 | 8.97 / 12.08 |
| Macro build mean / max, ms | 43.50 / 74.60 | 55.24 / 107.51 |
| Initial graphics/world fill, ms | 244.94 | 346.59 |
| Streaming p99 / max, ms | 0.1016 / 0.8369 | 0.0561 / 1.2114 |
| Resident Lua/FFI cache, KiB | 18,533 | 24,998 |
| Fixed region arrays plus scratch, KiB | 10,997 | 16,410 |
| Warm 4,000-chunk allocation, KiB | 0 | 0.816 |
| GPU height/material/water image, KiB | 1,225 | 1,225 |

Chunk median rises 21.5%; macro mean rises 27.0%. Extra coarse shape fields and
changed drainage geometry increase cold generation cost. Two cached material
threshold grids add 5.29 MiB including scratch. Material noise runs only over
32-block controls covering the region raster margin; curvature reuses existing
coarse heights. No per-column noise calls or objects were added. The warm allocation probe
recorded 0.816 KiB of LuaJIT bookkeeping across 4,000 chunks. Splitting final
material classification from fluid/bed handling avoids LuaJIT trace proliferation.
Streaming p99 is lower in this sample, but the maximum rose above 1 ms; these are
single-run measurements, not a guaranteed frame-time bound.

Shader, packed material IDs, textures and uploads are unchanged. Rendering was
visually checked through the existing game renderer; no new render benchmark was
run. Scene-dependent render cost can still change with mountain/water geometry.

The three-seed atlas and nine flying views show broad high shoulders, rounded
ridges, saddles, compressed summits and isolated sharp peaks, with irregular
snow/rock transitions. Voxel elevation steps remain visible. Detail-off maps retain
the broad shapes. The atlas helper now uses current region stride and margin;
its old hardcoded 257 stride produced incorrect hillshading.

Focused verification passed: exact positive/negative seams and independent build
order for all six cached fields, chunk/scalar height and material agreement,
downhill drainage, wet curved channels, coast/material checks, cache eviction,
far coordinates, streaming queues and buffer reuse. Hydrology algorithms are
unchanged; generated receivers naturally differ because mountain heights changed.

## Grass–stone boundary follow-up

Centered gradients interpolate across neighboring bed cells and use Euclidean
magnitude instead of max-axis magnitude. Broader threshold variation and reused
8-block detail interrupt angular grass/rock contours. Height generation, hydrology,
material encoding and shader remain unchanged; no new grids or noise evaluations
were added. Additional cached-bed reads increase chunk generation cost.

Current profile (`artifacts/grass-stone/generation.csv`, 2026-09-15): chunk median /
p99 14.02 / 19.59 µs; initial fill 396.92 ms; macro mean / max 61.18 / 129.02 ms;
streaming p99 / max 0.0915 / 0.9017 ms. Warm 4,000-chunk allocation: 0 KiB.
Previous Part 2.9 run was 8.97 / 12.08 µs per chunk on 2026-09-12; this is a
cross-day comparison, not a controlled same-session baseline.

Three-seed, nine-view renderer survey: `artifacts/grass-stone/flight-views.png`.
Focused surface tests pass exact material seams, independent build order,
chunk/scalar agreement, drainage and coastline checks. Logs: `artifacts/grass-stone/checks.txt`.

## Lossless shader optimization — 2026-09-15

Same RX 6700 XT / Mesa 26.2.2, seed 1337, current 556-block view distance,
native 1920×1080, AO and caves enabled. No quality, movement, view-distance,
generation, or frame-pacing settings changed.

Changes:

- Hardware repeat wrapping replaces shader modulo for height, span and maximum textures.
- Wall AO shares texture reads across three vertical samples per column: three column
  fetches replace eight independent occupancy queries. Corner weights stay identical.
- Chunk exit distances are computed only on chunk entry.
- AO shading runs after solid-hit traversal; unused trailing spans terminate their scan.
- Exact packed integer codes avoid redundant rounding and modulo during decoding.

The existing 1,200-frame moving benchmark measured 3.020 → 2.641 ms median,
4.362 → 3.940 ms p99, and 4.592 → 4.451 ms maximum. Median implies 14.4% higher
throughput for this render-plus-readback workload. These are sequential runs;
GPU synchronization/readback is included, desktop presentation and VSync are excluded.
VSync remains enabled in game, so displayed FPS remains refresh-rate limited.

A separate harness alternates old/new shaders on identical resident worlds:

| View | Before, ms | After, ms | Throughput increase |
| --- | ---: | ---: | ---: |
| Ground | 3.3675 | 3.0545 | 10.25% |
| Horizon | 2.7555 | 2.5021 | 10.13% |
| Downward | 2.3831 | 2.1405 | 11.33% |
| Cave | 2.3472 | 2.1858 | 7.39% |
| Cave ceiling | 1.8136 | 1.7469 | 3.82% |

Ocean and fractional-water fixtures also pass exact-pixel comparisons. All seven
scene fixtures plus 24 views across negative, region-boundary and million-block
coordinates match the original shader byte-for-byte. Streaming, packed-data,
chunk-skipping, water, AO and native-presentation regressions pass.

Generation routines, chunk storage, uploads and streaming policy are unchanged by
this optimization. The only world-side addition sets wrapping on four textures at
initialization/reload. Separate generation profiles show substantial LuaJIT/timing
variation (warm chunk median 11.20 → 8.46 µs, complex median 56.42 → 89.38 µs,
aggregate 72,758 → 70,239 chunks/s); these do not establish a generation speedup or
stable regression. No per-chunk work or texture storage was added.

Sources and raw evidence: `artifacts/fps-optimization/before/`, `baseline/`, `final/`,
`paired-final.txt`, and `generation-{before,after}.csv` in that directory.
Reproduce sequentially:

```sh
python3 tools/compare_render.py --reference artifacts/fps-optimization/before/raycast.glsl
python3 tools/benchmark.py --shader artifacts/fps-optimization/before/raycast.glsl
python3 tools/benchmark.py
python3 tools/profile_world.py --distance 556 --sources artifacts/fps-optimization/before
python3 tools/profile_world.py --distance 556
python3 tools/check_render.py
python3 tools/check_ao.py
luajit tools/check_streaming.lua
python3 tools/check_streaming_render.py
```

## Frame consistency: background generation — 2026-09-15

Cold-region construction previously ran synchronously when a visible chunk was
missing. That avoided holes but blocked presentation. Gameplay now starts one LÖVE
worker with its own terrain cache and Lua heap. Only finished chunk buffers reach
main-thread CPU storage and GPU uploads. No terrain generation runs in the gameplay
update path once the worker starts.

The preload ring grows from 5,329 to 7,569 chunks (eight chunks of padding), without
changing 556-block visibility. Transfer queues hold at most 32 jobs/results; obsolete
request tickets are rejected. Main-thread result consumption has a cooperative
0.5 ms budget. An individual GPU upload can overrun the remaining budget. The worker
blocks on its channel when idle and is joined on exit. First renderer use is warmed
at load time. Offline/synchronous world APIs remain available for tools and loading.

Movement never advances into missing visible chunks. Under exceptional worker
starvation it waits at the loaded boundary, allowing rendering/input to continue.
This is an explicit overload behavior, not an absolute constant-FPS guarantee.
The production physics test covered 599.006 blocks in 12 seconds (normal initial
acceleration included), with no lost sprint movement or main-thread terrain calls.

### Sequential paced sprint comparison

RX 6700 XT, Mesa 26.2.2, 1920×1080, seed 1337, 556-block view, diagonal movement
at 50 blocks/s for 1,440 frames scheduled at 120 FPS. The path enters cold macro
regions. Frame work includes GPU synchronization and full framebuffer readback;
desktop presentation/VSync is excluded. Both runs rendered identical settings.

| Metric | Before | Worker + preload |
| --- | ---: | ---: |
| Streaming median | 0.096 ms | 0.002 ms |
| Streaming p99 | 1.423 ms | 0.520 ms |
| Streaming maximum | 29.150 ms | 0.663 ms |
| Frame work median | 6.657 ms | 6.402 ms |
| Frame work p99 | 10.275 ms | 9.986 ms |
| Frame work maximum, excluding first resize frame | 37.919 ms | 10.709 ms |
| Unavailable visible views | 0 | 0 |
| Frames exceeding 8.33 ms work budget | 182 | 158 |

The first harness frame follows its own window/canvas resize and measured 18.430 /
18.919 ms; it is included in raw logs and deadline-miss counts. Production load warms
its actual initial canvas. Removing generation spikes does not remove variation in
GPU scene complexity: the demanding aerial path still exceeds a 120 FPS work budget
in some views. These measurements do not establish a guarantee at arbitrary FPS.

The existing 1,200-frame renderer benchmark measured 2.662 ms median / 3.972 ms p99,
versus the prior 2.641 / 3.940 ms run: roughly unchanged shader throughput. That
benchmark drives the synchronous world API, so it isolates the larger texture ring;
the separate sprint test measures the actual worker path.

Memory tradeoff: approximately 32.81 MiB more combined CPU/GPU ring buffers, plus
one worker-owned regional terrain cache. Ordinary transfer payloads are 1 KiB;
complex payloads are 5 KiB (at most 160 KiB across 32 in-flight buffers, excluding
channel/table metadata). World generation and shader algorithms are unchanged.

Validation covers deterministic worker heights/materials/water/spans, no main-thread
terrain generation, bounded queues, stale result rejection, teleports, stop/restart,
production movement at full sprint speed, exact GPU/CPU upload parity, rendering,
AO, collision and frame pacing. Source snapshot and raw per-frame CSVs are in
`artifacts/streaming-worker/`.

```sh
python3 tools/profile_streaming.py --sources artifacts/streaming-worker/before --output /tmp/stream-before
python3 tools/profile_streaming.py --output /tmp/stream-after
python3 tools/check_worker.py
python3 tools/check_worker_movement.py
python3 tools/check_render.py
python3 tools/check_ao.py
luajit tools/check_collision.lua
luajit tools/check_streaming.lua
luajit tools/check_frame_loop.lua
```
