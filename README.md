# loam

loam is a fullscreen terminal-cell painter written in Zig 0.16.0. every brush is a Lua script.

the engine stays small and direct:

- raw terminal mode, alternate screen, mouse input, paste, resize
- a persistent cell canvas plus a renderer-owned brush overlay
- rectangular selection, copy, paste, and visual-only moving selected cells
- a diffing renderer that patches changed terminal cells instead of clearing every frame
- a narrow Lua API for reading/writing cells, bulk drawing, particles, time, and random values

Lua owns the interesting part:

- what a brush is
- what glyphs it uses
- what number keys mean
- what gets placed on press, drag, release, paste, or frame
- whether a brush animates at all
- its corner preview frame

loam does not have Zig-side tool modes for default brushes. `box.lua`, `line.lua`, `eraser.lua`, `seed.lua`, and friends are just Lua files.

the same binary can also run the optional stdio MCP helper:

```sh
loam --mcp
```

it exposes `tools/list` and `tools/call`, with `loam_apply_selection` for rectangular text placement.

current version: **0.1.8**

## install

from a release:

```sh
curl -fsSL https://raw.githubusercontent.com/darkhorseprojects/loam/main/scripts/install.sh | sh
```

release assets are built for Linux x86_64, Linux aarch64, macOS aarch64, macOS x86_64, and Windows x86_64. BSD release assets are not published.

optional install location:

```sh
curl -fsSL https://raw.githubusercontent.com/darkhorseprojects/loam/main/scripts/install.sh | LOAM_INSTALL_DIR="$HOME/.local/bin" sh
```

on Windows PowerShell:

```powershell
iwr https://raw.githubusercontent.com/darkhorseprojects/loam/main/scripts/install.ps1 -UseB | iex
```

from source:

```sh
zig build
./zig-out/bin/loam --help
./zig-out/bin/loam --list
```

default optimization is `ReleaseFast`.

```sh
zig build -Doptimize=Debug
```

## run

```sh
zig build run
zig build run -- --brush=seed
zig build run -- --list
```

## controls

| input | action |
| --- | --- |
| number keys | sent to the active Lua brush as digit events |
| scroll wheel | cycle active brush, throttled for touchpads |
| left drag | active brush receives mouse press/move/release |
| left click | deselects the right-click selection only when it is a click, not while dragging |
| right drag | select a rectangular cell region |
| right release | copy selected text and keep the region selected |
| left drag inside selection | move selected cells; release commits and deselects |
| middle press | paste internal clipboard at mouse cell |
| `v` | paste at the last mouse cell |
| `c` | clear canvas and particles |
| `r` | clear selection / cancel move |
| `q` | quit |
| `esc` | cancel the active drag/move/selection gesture |
| repeated/held `esc` | top-left countdown `3 2 1`, then clear canvas instead of quitting |

## brush folders

loam loads every `.lua` brush from these locations, sorted by file stem:

- `./brushes`
- `$XDG_CONFIG_HOME/loam/brushes`
- `$HOME/.config/loam/brushes`
- `$XDG_DATA_HOME/loam/brushes`
- `$HOME/.local/share/loam/brushes`
- `/usr/local/share/loam/brushes`
- `/usr/share/loam/brushes`

the release installer also installs the bundled default brushes into the loam data dir, so the binary works from any cwd. after install, add user brushes with:

```sh
mkdir -p ~/.config/loam/brushes
cp my-brush.lua ~/.config/loam/brushes/
```

then run:

```sh
./zig-out/bin/loam --brush=my-brush
```

## mental model: a brush owns its placements

a brush is a Lua table with at least `paint(ctx, event)`. it may also provide `preview(ctx, width, height)`.

```lua
local brush = {
  name = "reed",
  glyph = "╎",
}

function brush.preview(ctx, width, height)
  return table.concat({
    "╎ ╎ ╎",
    "reed",
    "drag to draw",
    "1 style",
    "",
  }, "\n")
end

function brush.paint(ctx, event)
  if event.type == "mouse"
    and event.button == "left"
    and event.action ~= "release"
  then
    ctx.set(event.world_x, event.world_y, brush.glyph)
  end
end

return brush
```

when that brush writes a cell, it is making a permanent canvas edit. the engine does not remember which brush made which mark. later brushes simply see cells through `ctx.get(x, y)` and can build from them, erase them, ignore them, or overwrite them.

that is how the default natural brushes work:

- `soil` and `seed` place substrate directly.
- `moss` and `floral` look for nearby existing cells before growing.
- `eraser` writes spaces.
- `box` and `line` use staged previews while dragging, then commit on release.

## mouse events and holding the button

mouse input is event-based. the active brush receives:

```lua
{ type = "mouse", button = "left", action = "press",   world_x = 10, world_y = 5 }
{ type = "mouse", button = "left", action = "move",    world_x = 11, world_y = 5 }
{ type = "mouse", button = "left", action = "release", world_x = 12, world_y = 5 }
```

holding the mouse still does not automatically call the brush repeatedly. terminals send movement events when the pointer moves. if a brush wants continuous behavior while held still, it should store `down = true` on press, clear it on release, set `animated = true`, and do work on `frame` events.

example:

```lua
local brush = { name = "drip", glyph = "·", animated = true }
local held = nil

function brush.paint(ctx, event)
  if event.type == "mouse" and event.button == "left" then
    if event.action == "press" then held = { x = event.world_x, y = event.world_y } end
    if event.action == "move" and held then held = { x = event.world_x, y = event.world_y } end
    if event.action == "release" then held = nil end
  end

  if event.type == "frame" and held then
    ctx.set(held.x, held.y, brush.glyph)
  end
end

return brush
```

## animation and frame events

by default, brushes are not animated. loam does not call every brush every frame forever.

a brush gets `frame` events only when:

1. the active brush has `animated = true`, or
2. live particles exist.

this keeps ordinary drawing brushes cheap and still allows animated custom tools.

mouse interaction does not pause animation globally. if an animated brush wants to pause while dragging, that brush should do so in Lua by tracking its own state.

```lua
local brush = { name = "pulse", glyph = "*", animated = true }
local paused = false

function brush.paint(ctx, event)
  if event.type == "mouse" then
    paused = event.action ~= "release"
  elseif event.type == "frame" and not paused then
    -- animation work here
  end
end
```

## staged previews

the stage is a temporary overlay. it is useful for drag previews.

```lua
local drag = nil

function brush.paint(ctx, event)
  if event.type ~= "mouse" or event.button ~= "left" then return end

  if event.action == "press" then
    drag = { x = event.world_x, y = event.world_y }
  elseif event.action == "move" and drag then
    ctx.stageClear()
    ctx.stageSet(drag.x, drag.y, "┌")
    ctx.stageSet(event.world_x, event.world_y, "┘")
  elseif event.action == "release" and drag then
    ctx.commitStage()
    ctx.stageClear()
    drag = nil
  end
end
```

staged cells are visible but not permanent until `ctx.commitStage()`.

## number keys are brush-owned

Zig does not interpret brush presets. it only sends:

```lua
{ type = "digit", digit = 1 }
```

the active brush decides what `1`, `2`, `3`, etc. mean. in the shipped brushes:

- `box`: style, corner, fill, edge pattern
- `line`: line style with horizontal, vertical, diagonal, and reverse-diagonal glyph variants
- `eraser`: radius up/down
- `seed`, `soil`, `moss`, `floral`: size and glyph palette

digits also work during an active staged drag, so a brush can redraw its preview immediately.

## coordinates and glyphs

all Lua coordinates are 1-based terminal cells. top-left is `(1, 1)`.

use `event.world_x` and `event.world_y` for painting. `event.x` and `event.y` are viewport coordinates.

glyphs are Lua strings. each cell stores up to 8 UTF-8 bytes:

```lua
ctx.set(x, y, "▒")
ctx.set(x, y, "✿")
ctx.set(x, y, "🌸")
```

the engine will store and render them. your terminal/font decides whether a glyph occupies exactly one visual cell. for stable grids, prefer single-cell glyphs. emoji can look great in some terminals and misalign in others.

## ctx API

| function | meaning |
| --- | --- |
| `ctx.set(x, y, glyph)` | write one permanent cell |
| `ctx.get(x, y)` | read one cell, returns space outside the world |
| `ctx.stageSet(x, y, glyph)` | write one temporary preview cell |
| `ctx.stageGet(x, y)` | read staged cell |
| `ctx.stageClear()` | clear preview layer |
| `ctx.commitStage()` | commit staged cells into the world |
| `ctx.clear()` | clear canvas and particles |
| `ctx.width()` / `ctx.height()` | visible viewport size |
| `ctx.worldWidth()` / `ctx.worldHeight()` | persistent world size |
| `ctx.emit(x, y, glyph, ttl, vx, vy)` | create a particle |
| `ctx.particleCount()` | number of live particles |
| `ctx.getParticle(i)` | read particle fields |
| `ctx.setParticle(i, x, y, vx, vy, glyph, ttl)` | update one particle |
| `ctx.removeParticle(i)` | remove one particle |
| `ctx.eachParticle(fn)` | call `fn(index)` for each particle |
| `ctx.time()` / `ctx.dt()` | monotonic time and frame delta |
| `ctx.random()` / `ctx.randomRange(a, b)` | random values from Zig |

## event shapes

mouse:

```lua
{
  type = "mouse",
  button = "left" | "middle" | "right" | "wheel_up" | "wheel_down" | "other",
  action = "press" | "move" | "release",
  x = 1,
  y = 1,
  world_x = 1,
  world_y = 1,
  dt = 0.016,
  time = 12.34,
}
```

digit:

```lua
{ type = "digit", digit = 1 }
```

paste:

```lua
{ type = "paste", x = 1, y = 1, text = "copied text", positioned = true }
```

resize:

```lua
{ type = "resize", width = 120, height = 32 }
```

frame:

```lua
{ type = "frame", dt = 0.016, time = 12.34 }
```

## input and security boundary

loam draws a hard boundary between engine and brush code:

- Zig owns terminal IO, canvas memory, particles, selection, clipboard, and routing.
- Lua owns brush-local state, glyph choices, placement decisions, preview content, number-key behavior, and animation policy.
- A brush receives plain event tables and a small `ctx` API. it does not get Zig pointers, filesystem handles, network access, or process spawning from loam.
- Lua brushes are still trusted local code. the embedded Lua VM is initialized with standard Lua libraries, so a malicious brush can still do Lua-side damage inside the process.
- do not install random brushes from people you do not trust.

a future sandbox mode can tighten this further by opening only the functions loam explicitly exposes.

## project shape

```text
src/
  main.zig          app loop, args, input routing
  terminal.zig      raw terminal, mouse, paste, resize
  canvas.zig        world grid, stage, particles, render
  lua_bridge.zig    ctx/event boundary
  brushes.zig       brush discovery
  mcp.zig           optional stdio MCP helper server, also reachable through `loam --mcp`
brushes/
  box.lua
  eraser.lua
  floral.lua
  line.lua
  moss.lua
  particles.lua
  seed.lua
  soil.lua
docs/
  brush-api.md
  system.md
wiki/
  https://github.com/darkhorseprojects/loam.wiki
scripts/
  install.sh
```

## current architecture line

rendering never calls Lua. brush previews are rebuilt by the brush host after brush load or brush events, then cached as cells. the renderer composes durable canvas cells, particles, brush overlay, move overlay, selection, countdown, and cached preview into a diffed terminal frame.

canvas owns only durable cells and particles. selection, moves, preview, and brush drag overlays are visual/editor state, not canvas state.

## brush inventory

brushes are loaded into a Lua inventory for the lifetime of the app. switching away from a brush does not reset its Lua table; when you switch back, its style/radius/preset state is retained until loam exits.
