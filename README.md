# Love Raycast Survivor

GPU heightfield raycaster built with LÖVE and Lua. Supports true perspective
pitch, variable-height walls, jumping, collision, textured surfaces, cubemap
skybox, and configurable frame pacing.

## Run

Install LÖVE 11.5, then run from project directory:

```sh
love .
```

Game starts fullscreen with captured mouse.

| Control | Action |
| --- | --- |
| WASD | Move |
| Mouse | Look |
| Shift | Sprint |
| Space | Jump |
| F2 | Toggle CRT effect |
| Escape | Quit |

## Configuration

Edit `CONFIG` in `main.lua`, then restart:

- `CRT_ENABLED`: enable CRT post-processing at startup; F2 toggles it live.
- `VSYNC`: synchronize presentation with display refresh.
- `MAX_FPS`: FPS target when VSync is off; `0` means uncapped.
- `RENDER_W`, `RENDER_H`: fixed internal resolution, default 320×240 (4:3).
- `FOV_DEG`, `VIEW_DIST`: field of view and rendering distance.

Maps live in `levels.lua`. Current renderer uses first map. Cell values `0`,
`1`, `2`, and `3` represent empty space and solid columns of corresponding height.
Walls use `bricks.png`; floors and column tops use `ground.png`.
Skybox uses `skybox/blink/cubemap.png`.

`crt-lottes-fast.glsl` adapts Timothy Lottes’ public-domain CRT filter for LÖVE.
Scene scales uniformly to fit display, centered with black borders.
It filters scene and HUD together during upscale. HUD uses 16px
`Px437_IBM_VGA_8x16.ttf` with nearest filtering. Shader
constants control scanlines, mask, curvature, and gamma. Disabled CRT skips
post-processing. Original attribution and license remain in shader file.

## Checks

Run from project directory with LuaJIT installed:

```sh
luajit tools/check_collision.lua
luajit tools/check_frame_loop.lua
```

Offscreen rendering benchmark requires Python 3 and LÖVE:

```sh
python3 tools/benchmark.py
python3 tools/benchmark.py --baseline /path/to/previous/main.lua
```

See [PERFORMANCE.md](PERFORMANCE.md) for measurement details and tradeoffs.
