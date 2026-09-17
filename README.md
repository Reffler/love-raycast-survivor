# Infinite Voxel World

Seeded block terrain in LÖVE 11.5: continents, oceans, plains, mountain chains,
snowy ridgelines, valleys, rivers, lakes, beaches, cliff coasts, underground caves,
tunnels, chambers, entrances, ravines and rock bridges. Grass/dirt textures,
ambient occlusion, pixel-locked sun shadows and a configurable day/night cycle.
Native display resolution; no post-processing.

```sh
love .
```

WASD moves, mouse looks, Shift sprints, Space jumps, F3 toggles diagnostics,
F4 toggles sun/moon shadows, F5 toggles temporal AA,
Escape quits. Double-tap Space within 0.3 seconds toggles flight. Space rises,
Ctrl descends, Shift flies faster; release vertical controls to hover. Flight
retains terrain collision. Water has a visible surface; swimming is not implemented.

## Configuration

Edit `CONFIG` in `main.lua`:

- `SEED`: deterministic integer seed, default `1337`.
- `SEA_LEVEL`: ocean surface height, default `48`.
- `OCEAN_FLOOR`: deep-ocean elevation, default `8`.
- `CONTINENT_SCALE`: spacing of macro continent controls, default `2048` blocks.
- `DETAIL_HEIGHT`: small surface detail amplitude, default `1.25`; `0` retains macro geography.
- `VIEW_DIST`: visible distance, default `556` blocks.
- `DAY_CYCLE_SECONDS`: full day/night duration, default `20`; use `1200` for 20 minutes.
- `FOG_ENABLED`, `FOG_START`: atmospheric distance fog; enabled, starts at `0.35` of view distance and reaches sky color at the far limit.
- `AA_ENABLED`: temporal anti-aliasing, default `true`; toggle with F5. F3 HUD shows state. Off uses one center ray.
- `SHADOWS_ENABLED`: directional solid-geometry shadows, default `true`; toggle with F4.
- `SHADOW_DISTANCE`: maximum shadow-ray length, default `96` blocks, range `0–128`.
- `SUN_STRENGTH`, `AMBIENT_STRENGTH`: direct/ambient light, defaults `0.72` / `0.28`.
- `MOON_STRENGTH`, `NIGHT_AMBIENT_STRENGTH`: moon direct/night ambient, defaults `0.32` / `0.48`; moonlight uses the same pixel-locked shadows.
- `CAVES`: cached volumetric caves and surface openings, default `true`.
- `PLAYER_HEIGHT`: physical body height, default `1.80`; camera remains at `1.62`.
- `CAM_HEIGHT`: player eye height, default `1.62` blocks.
- `VSYNC`, `MAX_FPS`, `FOV_DEG`: frame pacing and camera settings.

`Terrain.defaults` in `terrain.lua` also exposes independent `mountainMask`,
`ridgeField`, and `terrainVariation` spacing/seed settings. Pass overrides as the
third argument to `World.new(seed, viewDistance, config)`. Mountain mask thresholds,
ridge width, and domain warp are independent. Sea/floor heights are integers;
current generated surfaces stay within 0–254 blocks for compact encoding.

## Surface generation

`geography.lua` evaluates expensive fields only on a coarse global grid. Warped
continentalness shapes deep ocean → shelf → coastline → plains → inland terrain.
Warped Voronoi edges form connected ridge networks. Regional masks/amplitude select
mountain systems. Height combines broad massif uplift (50%), medium shoulders
(30%) and a narrower crest (8–28%, strongest only in selected areas). A continuous
1408-block mountain-type field changes massif width, crest sharpness and cliff
strength. A separate 896-block field compresses upper relative heights and shapes
intermediate shoulders, with spatially varying knees instead of fixed terraces.
Small detail decorates this structure rather than determining it.

`regions.lua` caches nine 1024×1024-block macro regions. Drainage uses globally
jittered nodes approximately 32 blocks apart. Each node drains to its steepest
lower neighbor. Flow accumulates along this graph; high-flow edges become streams
and rivers, with width/depth increasing with flow. `river_geometry.lua` samples
cubic Hermite centerlines about every 2.5 blocks. Shared endpoint tangents follow
incoming/outgoing drainage directions; modest world-noise displacement softens
the routing grid without moving drainage endpoints. Lake outlets pass through
their actual spill node. Rotated, noise-warped lake shorelines replace pure discs.
Binary sub-block curve samples and stable voxel rounding keep diagonal lips
identical across region translations.
`hydrology.lua` follows complete downhill paths, including destinations beyond the
region halo, and memoizes the result during each macro build. Every ocean-bound
river uses exactly `SEA_LEVEL`. Inland sinks use their lowest D8 rim as a shared
`lakeWaterLevel`; tributaries inherit that basin datum. High inland rivers use
24-block elevation bands for reach metadata. Every receiver path is checked for
solid support loss, even when upstream/downstream metadata matches. Lakes retain
their lowest D8 spill node and use its outward downhill neighbor as the outlet;
the receiver/accumulation graph remains unchanged. Geometry narrows toward that
outlet or river lip, rather than spilling across an entire perimeter.

River beds are independent of water elevation. Smooth cross-sections deepen toward
the center, with 2-block edge depth and approximately 3–5 blocks at ordinary river
centers. Later bank shaping never refills existing wet beds. Inland river shoulders
sit at least one block above water; a four-block guard in `Terrain:finish()` covers
interpolated dry shorelines. The existing sea-level
carving branch and beach material rules remain separate from this inland guard.
Inland lake/reach levels take priority even when carved beds lie below sea level.

`fluid.lua` builds sparse block geometry once per cached region. `FULL`, `FLOW_1`
through `FLOW_7`, and `FALLING` describe source water, eighth-block surface steps,
and continuous falling columns. Upper channels taper gradually toward a lip width
of `clamp(round(channelWidth * 0.55), 2, 8)` columns. Each lane finds unsupported
air immediately downstream of its backing column. Falling records never lower
terrain; explicit terrain floors preserve the backing cliff and fall support.
Cardinally connected shallow lip records join feeder to every falling lane.
Landings use
a deterministic D4 flood, preferring downward outlets before supported horizontal
routes. Each landing restarts FLOW_1..7; a separate fourteen-step travel bound caps
secondary falls. One-block drops use eighth-block ramps. Incoming horizontal flow
merges into existing lakes at their surface level. Different basin surfaces receive
separating inland banks. No per-frame fluid updates or drainage graph changes occur.

Accumulation saturates at 32 contributing cells, bounding maximum river size.
A 36-cell halo exceeds the dependency radius plus raster margin. Thus independently
generated neighboring regions produce identical shared controls, including water
and river valleys. Accumulation remains capped; destination tracing is not cut off
by that cap or by region boundaries. Region coordinates do not alter routing or
introduce artificial outlets.

River carving and erosion-like shaping occur on cached regional controls, spaced
four blocks apart after coarse routing. No per-block erosion simulation. Macro work
runs on a dedicated worker during gameplay; the same work runs synchronously during
initial loading. A 32-block geometry margin supports boundary-consistent landing and bank stencils.
Region cache uses approximately 16.03 MiB of fixed arrays plus sparse fluid records.

`World:generateChunk(cx, cy)` fills a whole 16×16 chunk using reused buffers and
scratch interpolation arrays. Chunk loops allocate no objects and perform no
expensive noise evaluations. Sparse fluid records are indexed by overlapping chunk
during macro generation, so chunk generation reads only its own records. Returned
chunk belongs to the ring cache and is valid
until its slot is reused. `World:height(x, y)` retains the original surface elevation for generation and
diagnostics. Collision uses `isSolid`, `floorBelow`, `ceilingAbove` and `overlaps`;
cache misses evaluate the same regional primitives with reused scratch buffers.

Surface IDs are generated once per block:

| ID | Material | Selection |
| --- | --- | --- |
| 0 | Grass | Normal dry lowlands and gentle slopes |
| 1 | Sand | Gentle, variable-width coastal bands and shallow shelves |
| 2 | Rock | Steep slopes and cliff coasts |
| 3 | Snow | High, cold terrain; steep faces retain rock |
| 4 | Dirt | Deep ocean floor; grass block sides also use dirt |

Snow and rock thresholds use domain-warped geology/elevation fields and a coherent
64-block patch mask, sampled only at 32-block controls. A four-neighbor height
Laplacian marks convex ridges as more exposed and concave gullies as more sheltered.
Snow descends into sheltered faces; broad gentle shoulders retain grass or snow.
Thresholds interpolate through cached grids. Chunk generation reuses buffers and
classifies materials in a separate pass to keep LuaJIT branch combinations bounded.

Beaches depend on slope and a varying coastal band; ocean cliffs do not receive
sand merely for being near sea level. Snow elevation varies with regional climate.

## Streaming and rendering

Default settings retain 7,569 chunks (1392×1392 blocks), including eight chunks of
prefetch padding around the unchanged 556-block view. Offsets sort once. Normal
movement requests only incoming rows/columns; teleports rebuild from presorted
offsets. Chunk buffers and queue links are reused. `terrain_worker.lua` owns a separate
Lua state and terrain cache: cold-region builds, chunk generation and their garbage
collection stay off the render thread. At most 32 jobs/results are in flight.
Completed buffers are copied/uploaded with a cooperative 0.5 ms per-frame budget;
individual uploads can exceed the remaining budget. Request tickets discard obsolete
results after reversals or teleports. Shutdown joins the worker cleanly.

Movement checks visible residency plus enabled shadow reach before advancing. If the worker falls behind,
movement waits at the loaded boundary instead of exposing recycled terrain or
blocking a frame to generate it. Normal 50-block/s sprint tests need no such waits.
The renderer's first use is warmed during loading. Synchronous `World:step` remains
available for initial loading, offline tools and deterministic tests.

`chunk.data` stores `uint16_t[256]` heights. `chunk.surface` stores a packed material
ID and water height: `material * 2048 + waterTop * 8`; zero water means dry.
The existing `rg16f` GPU image stores `R = terrainHeight * 8 + materialID` and
`G = waterTop * 8`. R stays at or below 2036; G stores exact eighth-block heights.
Shader decoding uses exact integer R, R - floor(R / 8) * 8 for material, floor(R / 8) for terrain,
and G / 8 for water. FFI writes a contiguous upload buffer; one
16×16 upload plus one chunk-maximum upload updates the GPU, with no per-pixel
`setPixel()` calls or extra material texture fetch. CPU images mirror uploads for
window/display-mode reloads. Collision still uses terrain bed height, not water.

Ray traversal skips chunks above their maximum solid/water height. The shader
selects grass/dirt textures or flat material colors and intersects water tops, vertical drop
faces, and terrain beds in ray order. Fractional water tops use four shared corner
heights and two ray/triangle intersections; compatible full/falling neighbors force
full-height edges. Eight extra neighbor reads occur only when a ray encounters a
fractional water surface. Full ocean tops and dry traversal avoid these reads. It does
not classify procedural terrain. Analytic grid crossings avoid accumulated ray
rounding differences. GPU coordinates remain near camera for long-distance travel.
All water surfaces and falling faces share one color. Bed depth and fall height
do not introduce dark pools or rectangular color boundaries.

## Checks and previews

```sh
luajit tools/check_world.lua
luajit tools/check_surface.lua
luajit tools/check_water.lua
luajit tools/check_waterfalls.lua
luajit tools/check_river_geometry.lua
luajit tools/check_topology.lua
python3 tools/check_waterfall_render.py
luajit tools/check_collision.lua
luajit tools/check_frame_loop.lua
python3 tools/check_render.py
python3 tools/profile_world.py --stage full
python3 tools/benchmark.py
```

Optional visual tools require Pillow:

```sh
python3 tools/surface_atlas.py
python3 tools/surface_views.py
```

The survey uses reproducible random seeds `65168`, `716701`, and `452312`.
[Atlas](artifacts/surface-v2/atlas.png) compares 4096×4096-block maps with and without
detail. [Flying views](artifacts/surface-v2/flight-views.png) capture actual rendering
at 768-block QA view distance; normal game distance remains 256.

[PERFORMANCE.md](PERFORMANCE.md) contains feature-by-feature profiles and scope.
Advanced biome systems, block editing, aquifers and flooded caves remain outside scope.

Part 2.6 checks: `luajit tools/check_flow.lua`, `luajit tools/check_water.lua`,
`python3 tools/check_render.py`, and `python3 tools/check_flow_render.py`.
Generated waterfall/landing previews and native flat-versus-sloped timings live in
`artifacts/part2-6-flow/`; before/after performance is recorded in `PERFORMANCE.md`.

Part 2.7 support-loss, outlet, ramp, boundary and color fixtures are captured in
`artifacts/part2-7-views/`. A real same-level lake outlet in seed 33 appears in
`artifacts/part2-7-natural/overview.png` (metadata 76/76; rendered fall 76→63).

Part 2.8 previews: [broad fall](artifacts/part2-8-views/broad-river-40.png),
[small stream](artifacts/part2-8-views/small-stream-40.png),
[curved channels](artifacts/part2-8-views/curved-channel-1337.png), and
[natural outlet](artifacts/part2-8-natural/overview.png).
Geometry checks cover flow-scaled widths, solid backing, feeder-to-landing water
occupancy, recessed channels, shared tangents and warped lake outlines. Existing
boundary/order, packed surface, collision and water-color checks remain active.

Part 2.9 mountain survey: [three-seed aerial atlas](artifacts/part2-9/atlas.png)
and [actual flying views](artifacts/part2-9/flight-views.png), covering seeds
65168, 716701 and 452312. Both detail-on and detail-off maps are included.
Reproduce with `python3 tools/surface_atlas.py --output artifacts/part2-9` and
`python3 tools/surface_views.py --output artifacts/part2-9` (Pillow required).

Grass–stone transition fix: centered Euclidean gradients replace axis-max slopes,
and stronger warped geology patches combine with the existing eight-block detail
field near mountain material transitions. This removes grid-direction bias and
breaks smooth grass/rock borders into interlocking patches without changing heights
or adding procedural noise calls per column. [Rendered survey](artifacts/grass-stone/flight-views.png).

## Volumetric terrain (Part 3)

Each column has at most four sorted solid spans, stored as reusable `int16_t[8]`
records on CPU. Solid membership uses `lo <= z < hi`; floor and ceiling planes
remain at integer boundaries. Two `RGBA16F` GPU images hold
`lo0 hi0 lo1 hi1` and `lo2 hi2 lo3 hi3`; unused pairs are `-1`.
The existing height/material/water image retains the uncarved surface height and
material. Chunk maxima contain actual surviving solid/water height plus `512`
when spans are needed. Ordinary chunks retain the heightfield rendering path.

The renderer keeps XY DDA. Inside each complex XY cell it tests the current ray
segment against a compile-time maximum of four intervals, including floors,
ceilings and vertical walls. Interior faces use rock; surviving surface tops keep
their original material. Water stays separate and competes for the nearest hit.
No Z voxel traversal, density volume or 3D raymarching is used.

`caves.lua` creates a globally deterministic graph on jittered 192-block cells.
Canonical neighbor edges and diagonal branches form tunnels, junctions and loops;
large ellipsoidal chambers are sparse among smaller junction rooms. Midpoint bends
break straight runs. Coarse terrain context selects cliff mouths and descending
shafts, narrow ravines, and bridges with two exposed ends and a retained center
roof. Entrances connect to the underground graph. Generation never raises terrain.

Capsules and ellipsoids are spatially binned to affected chunks once per cached
macro build. Conservative projected-distance tests discard empty diagonal bins.
Chunk generation computes vertical air intervals analytically, merges their cuts,
and subtracts them from the base column. Existing coherent eight-block detail
roughens radii; there are no new per-column noise calls or per-voxel objects.
Macro cave work yields between primitives. Chunk buffers and cut scratch are reused.

Ocean-floor columns are excluded. Wet columns retain six solid blocks below their
bed; nearby dry banks use the water datum rather than their potentially much higher
surface. Low coastal ground has an additional conservative cap. This also prevents
lateral openings into rivers/lakes. Water-connected caves are not generated.

Cavities smaller than two blocks are discarded; cuts separated by at most one block
merge. Pathological inputs exceeding four solid spans discard their smallest
remaining cavities and increment `world.spanOverflowCount` (reduction events, not
unique coordinates). Four-seed, 4.19-million-column survey recorded zero overflows.

Movement uses the full player footprint against solid spans, supports cave floors
and ceilings, blocks low overhangs, and handles jump/flight ceiling crossings.
The camera stays 0.18 blocks below the physical head when pressed against a roof.
Single-span columns retain a direct height comparison for collision.

At view distance 556 with worker prefetch, fixed span images use **29.57 MiB GPU**.
CPU collision records use another **29.57 MiB**, and reloadable CPU image mirrors
use **29.57 MiB**. The height/material/water GPU image uses 7.39 MiB. The larger
prefetch ring adds approximately 32.81 MiB across CPU/GPU buffers; the worker owns
an additional terrain cache. Fixed storage won the
render comparison against a compact sparse page atlas; detailed timings and the
memory tradeoff are in [PERFORMANCE.md](PERFORMANCE.md).

Seed 1337 nearby features (world coordinates):

- Cliff entrance: approximately `(-279, -263, 80)`.
- Rock bridge: approximately `(-215, 293, 133)`.

[Entrance](artifacts/part3/entrance-1337.png),
[underground junction/chamber](artifacts/part3/chamber-1337.png),
[rock bridge](artifacts/part3/arch-1337.png). Additional views cover seeds 716701 and
452312. Use double-tap Space to fly, Space/Ctrl vertically, and F3 for position.

Focused reproduction:

```sh
python3 tools/check_spans.py
luajit tools/check_caves.lua
luajit tools/check_collision.lua
python3 tools/cave_views.py
python3 tools/profile_spans.py
python3 tools/profile_world.py --distance 556
```

The single-span GPU gate runs with caves disabled and compares exact framebuffers
against the preserved pre-span shader, including water, waterfalls, negative
coordinates, macro boundaries, chunk skipping and reload. Further probes verify
four-span floors/ceilings, interior walls, upper materials, half-float packing and
unused `-1` values. Natural cave views also match unaccelerated XY DDA exactly.

## Pixel-locked shadows

Solid receivers snap to world-space 16×16 face texels before a binary sun ray.
Chunk maxima skip empty space; complex chunks use cave/overhang intervals.
Direct sun/moon light fades between 12° and 18° elevation; below 12° no shadow rays run.
Water neither casts nor receives shadows. No extra persistent GPU textures.

[Profiling and validation](artifacts/pixel-shadows/REPORT.md) includes all five
views at disabled/32/64/96/128-block settings. Reproduce with:

```sh
python3 tools/shadow_tools.py check
python3 tools/shadow_tools.py profile
python3 tools/benchmark.py --shadow-distance 96
```

Atmosphere uses a horizon-to-zenith sky gradient, warm directional sunlight, cool
moonlight and blue ambient fill. Distance fog shares sky colors across solid terrain
and water. All shading stays in the existing raycaster, with no new texture reads
or render passes; day/night palettes update once per frame.

Grass/dirt use nearest-neighbor LOD-0 textures. Shadow visibility remains binary
at world-space 16×16 receivers before temporal resolve.

### Temporal anti-aliasing

F5 toggles temporal AA; F3 HUD shows `TAA` or `off`. Enabled mode traces and shades
one ray per pixel, with a repeating 16-position Halton jitter. A separate resolve
reprojects color history using camera transforms and signed forward depth. History
uses an unjittered output grid, with depth-tested bilinear taps and neighborhood
color clamping. Local sky/solid boundaries retain mixed coverage so thin silhouettes
do not reset history on every jitter step. Water uses shorter history.

History resets on toggles, resize/FOV changes, teleports and large camera rotations.
Camera displacement uses world coordinates, so 16-block cache-origin rebases do not
move history. HUD draws after resolve and never enters history. Off mode traces
one unjittered ray and skips temporal passes. No thin-top color/lighting alteration.

Temporal accumulation reduces shimmer but can soften detail and leave brief edge
trails during disocclusion. It does not guarantee zero aliasing. Three RGBA16F
buffers add about 47.5 MiB at 1920×1080; buffers remain allocated while AA is off.

The old four-ray renderer is removed from production. Its source is archived only
for benchmarks under `artifacts/temporal-aa/msaa4/`. Run:

```sh
python3 tools/temporal_tools.py check
python3 tools/temporal_tools.py profile
```

The profile compares archived 4× against current TAA using identical ground,
horizon, downward, cave, cave-ceiling and moving-ground views. Exact geometry tests
explicitly disable TAA; temporal-specific tests cover accumulation and history.

## Water appearance

Water traces reflected and refracted rays through existing chunk maxima and solid
intervals, showing actual mountains and submerged block faces. Refraction bends at
the surface; colored absorption grows with actual underwater ray length. Reflection
rays stop at view distance/cache bounds; underwater rays stop at 96 blocks or the
absorption limit. Unavailable cache slots are never sampled.

Secondary hits use material textures and directional/ambient lighting, without
additional AO or shadow rays. Water is excluded from secondary intersections to
prevent recursion. Reflections therefore show solid terrain and sky, not other water
surfaces; refraction models one interface. Fully fogged water skips both rays.
No extra render pass or persistent textures. Water-heavy views now cost up to two
additional geometry traversals per pixel; performance has not been profiled.

`WATER_WAVE_STRENGTH` defaults to `0.035` (`0` disables ripples).
`WATER_ABSORPTION` defaults to `0.22`; increase for murkier water.

Water reflections use the geometric surface normal for a stable, clear terrain
image. Gentle animated normals affect refraction only. Blue tint applies to the
transmitted water body, preserving reflected landscape contrast; reflection starts
at 12% and strengthens toward grazing angles. No extra rays or passes are added.

## Stars and clouds

Night sky has fixed square stars fading in after sunset. Slow 16-block cloud patches
cross the sky and cover stars/sun/moon, with cooler nighttime colors. Clouds use
a bounded grid traversal within a thin slab, stopping at the first occupied column; water sky reflections
include them. No added textures or render passes. Cloud layer is a sky effect and
does not cast terrain shadows.

`STARS_ENABLED` / `CLOUDS_ENABLED` toggle each layer. `CLOUD_HEIGHT` defaults to
320 blocks; `CLOUD_SPEED` defaults to 0.7 blocks/second.
`CLOUD_THICKNESS` defaults to 16 blocks. Connected cloud faces have uniform color,
with darker vertical sides and no internal tile borders.
