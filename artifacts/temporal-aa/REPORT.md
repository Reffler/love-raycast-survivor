## Temporal AA replacing 4× coverage — 2026-09-17

Matched RX 6700 XT / Mesa 26.2.2 runs, 1920×1080, 556-block view,
96-block shadows, 200 timed frames after 32 warmups. Readback and complete
presentation path included; no simultaneous GPU test runs during final profile.
Baseline is the immediately preceding nearest-textured 4× implementation, not
the older single-ray mipmapped renderer. 4× source remains benchmark-only.

| View | 4× median / p99 / max ms | TAA median / p99 / max ms | Median reduction |
|---|---|---|---|
| ground | 14.143 / 14.630 / 16.682 | 3.285 / 3.857 / 5.264 | 76.8% |
| moving-ground | 14.184 / 14.671 / 14.680 | 3.321 / 4.494 / 5.341 | 76.6% |
| horizon | 10.710 / 11.282 / 11.549 | 2.779 / 3.241 / 3.416 | 74.1% |
| downward | 10.690 / 10.967 / 11.146 | 2.581 / 2.698 / 2.813 | 75.9% |
| cave | 9.274 / 9.453 / 9.463 | 2.442 / 2.603 / 2.636 | 73.7% |
| cave-ceiling | 6.223 / 6.541 / 6.752 | 1.963 / 2.163 / 2.168 | 68.5% |

One geometry ray and at most one AO/shadow evaluation per pixel replace four
coverage rays and variable shading groups. A 16-position Halton sequence feeds a
full-resolution temporal resolve. Current color and signed forward depth share
RGBA16F; two ping-pong history buffers store resolved color/current depth. Extra
allocation is 47.46 MiB at 1080p. F5 off bypasses jitter and temporal passes but
keeps allocations for instant toggling. F3 HUD is drawn after history resolve.

Camera reprojection uses an unjittered grid and world camera deltas, preserving
history across cache rebases. Individual history taps are depth/category tested;
local surface depth intervals accommodate subpixel top/side changes. Sky/solid
edge neighborhoods allow mixed history coverage. Current 3×3 color bounds clamp
history; water history weight is capped at 0.5. Normal history weight reaches
15/16. Resize, FOV, AA/shadow toggles, >8-block camera jumps and large camera turns
reset history. Small lighting changes converge over successive frames.

Controlled staircase at 320×180: static RGB RMS frame change 10.783 raw jittered
→ 0.790 resolved; tiny continuous translation crossing a cache rebase 10.780 →
0.930. These measure stabilization against jittered single samples, **not** a
quality comparison against 4×. They do not prove absence of all ghosting/shimmer.
GPU probes verify XY reprojection, depth/disocclusion rejection, sky translation,
silhouette-local mixed history, water history limit, screen bounds, toggles,
resize/FOV/camera resets and HUD isolation. Close-up nearest texture sampling and
binary world-snapped shadow tests remain unchanged before temporal accumulation.

Tradeoffs: temporal resolve softens some fine detail; local edge history can leave
brief trails at disocclusions, and lighting changes take frames to settle. No
claim of complete aliasing elimination. Thin-top color blending remains removed.

Reproduce: `python3 tools/temporal_tools.py profile` and
`python3 tools/temporal_tools.py check`. Raw CSVs, screenshots and baseline source
are in `artifacts/temporal-aa/`.
