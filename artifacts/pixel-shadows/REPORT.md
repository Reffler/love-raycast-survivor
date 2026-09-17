# Pixel-locked directional shadows

## Measurement

RX 6700 XT, Mesa 26.2.2, native 1920×1080, seed 1337, 556-block view,
AO/textures/caves enabled. Sequential runs. Timings include rendering, GPU
synchronization and framebuffer readback; exclude presentation/VSync. These are
render-time measurements, not isolated GPU timer queries or guaranteed frame bounds.

Fixed-view runs use 60° sun elevation, 20 warmup frames and 200 measured frames
per case. Production shaders supply timings. A separate instrumented shader pass
supplies traversal counters; production contains no counter overhead.

[Full 30-case CSV](profile.csv) records original shader plus disabled/32/64/96/128
for ground, horizon, downward, cave and cave-ceiling views, including every
requested timing and traversal metric. [Raw log](profile.txt).

| View | Disabled median | 96 median | 96 p99 | 96 maximum | Added median |
| --- | ---: | ---: | ---: | ---: | ---: |
| Ground | 3.069 | 3.214 | 3.366 | 3.551 | 0.145 |
| Horizon | 2.528 | 2.621 | 2.890 | 2.972 | 0.094 |
| Downward | 2.173 | 2.438 | 2.656 | 2.730 | 0.265 |
| Cave | 2.210 | 2.264 | 2.547 | 2.638 | 0.054 |
| Cave ceiling | 1.755 | 1.764 | 2.056 | 2.158 | 0.009 |

All times in milliseconds. Downward view has largest relative median cost (12.2%),
because most pixels face the sun. At 96 blocks:

| View | Fine cells/front pixel | Chunks skipped/front pixel | Back-facing solid % | Above maxHeight/rays % | Occluded/rays % |
| --- | ---: | ---: | ---: | ---: | ---: |
| Ground | 9.537 | 3.994 | 52.108 | 0 | 15.729 |
| Horizon | 7.477 | 3.569 | 80.684 | 24.073 | 25.719 |
| Downward | 7.248 | 3.738 | 17.022 | 17.090 | 20.635 |
| Cave | 4.929 | 0 | 64.804 | 0 | 100 |
| Cave ceiling | 1.236 | 0 | 95.272 | 0 | 100 |

Front pixel means front-facing solid receiver eligible for a shadow ray, including
receivers ultimately occluded. Fine cells count actual height/span tests, excluding
skipped chunks. Backface percentage uses all solid pixels; termination percentages
use cast rays. Above-height includes termination at the analytically computed
maxHeight limit. CSV also records complex-cell work and cache/pending exits.
Every profiled case had zero cache-bound or pending-slot exits.

Most work occurs in the first 7–10 cells outdoors. Raising distance mainly adds
cheap chunk skips: ground cell count is almost identical from 32 through 128.
Cave rays hit nearby rock after 1–5 complex cells. This supports keeping 96 as
default; shortening distance alone would save little in these scenes.

### Established 1,200-frame moving benchmark

| Renderer | Median | p99 | Maximum |
| --- | ---: | ---: | ---: |
| Current pre-shadow renderer | 2.747 | 4.039 | 4.369 |
| New renderer, shadows disabled | 2.742 | 4.019 | 4.304 |
| New renderer, 96 blocks | 2.889 | 4.231 | 4.568 |

Default shadows add 0.142 ms median (5.2%) and 0.192 ms p99 versus fresh baseline.
Historical 2.641/3.940 measurements preceded grass/dirt textures and day/night;
fresh matched baseline avoids attributing those changes to shadows. This harness
uses synchronous streaming; separate production-worker movement validation covered
599.006 blocks in 12 seconds without lost sprint distance or main-thread generation.
Raw moving data lives in `moving-before/`, `moving-disabled/`, and `moving-96/`.

## Implementation and bounds

- One continuous unit sun direction follows day/night; starts at 60° elevation.
- World-space receiver texels have 1/16-block spacing on every solid face.
  Perpendicular coordinate remains on its integer face, then offsets outward .002.
- Binary secondary XY DDA runs only after a solid hit and positive N·L.
  Ordinary chunks read heights; complex chunks read four solid intervals.
- Distance defaults to 96, capped at 128 and the analytical world-ceiling exit.
  Direct light fades from zero at 12° to full at 18°; lower sun casts no rays.
- Existing eight-chunk margin remains unchanged. Movement readiness includes
  configured shadow reach. Pending slots use marker 1024 in existing maximum
  texture, restored on upload or reversal. Explicit bounds prevent cache wrapping.
- Exceptional missing/out-of-bounds rays terminate lit instead of reading stale
  geometry. Thus unavailable data can truncate a shadow, not invent blockers.
- No extra persistent GPU textures, filtered shadows, mesh pass or water shadows.
  Original AO and day/night tint remain; fake cardinal shading is removed.
- F4 toggles shadows; CONFIG exposes distance, direct strength and ambient strength.

## Validation

[GPU check log](check.txt) covers binary shadow agreement with independent analytic
ray/box intersections, top and all four wall orientations, four solid intervals,
roofs/openings/arches, negative chunk seams, vertical rays, distance/ceiling bounds,
chunk skips, pending slots and reversal. Low-sun/backface/toggle cases perform no
shadow work; water neither receives nor casts shadows.

Actual camera traversal preserves visibility for 144,154 shared receiver samples
under .01-block translation across an origin rebase and camera rotation. Continuous
sun movement changes whole world texels; oversampled 4×4 groups never split.
Artifacts include textured grass camera pairs, top/wall masks and five natural views.
Worker parity/stale-job/teleport/restart, sprint, collision, streaming and frame-loop
checks also pass.

```sh
python3 tools/shadow_tools.py check
python3 tools/shadow_tools.py profile
python3 tools/benchmark.py --shader artifacts/pixel-shadows/before/raycast.glsl
python3 tools/benchmark.py --shadow-distance 0
python3 tools/benchmark.py --shadow-distance 96
python3 tools/check_worker.py
python3 tools/check_worker_movement.py
luajit tools/check_collision.lua
luajit tools/check_streaming.lua
luajit tools/check_frame_loop.lua
```
