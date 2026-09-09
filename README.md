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
| Escape | Quit |

## Configuration

Edit `CONFIG` in `main.lua`, then restart:

- `VSYNC`: synchronize presentation with display refresh.
- `MAX_FPS`: FPS target when VSync is off; `0` means uncapped.
- `RENDER_SCALE`: internal resolution relative to window dimensions.
- `FOV_DEG`, `VIEW_DIST`: field of view and rendering distance.

Maps live in `levels.lua`. Current renderer uses first map. Cell values `0`,
`1`, `2`, and `3` represent empty space and solid columns of corresponding height.
Walls use `dirt.png`; floors and column tops use `grass.png`.
Skybox uses `skybox/blink/cubemap.png`.

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
