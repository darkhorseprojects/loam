# brush api

a brush is one Lua file in `./brushes`, `~/.config/loam/brushes`, `~/.local/share/loam/brushes`, or the system share dirs. it returns a table:

```lua
local brush = {
  name = "brush name",
  glyph = "*",
  animated = false,
}

function brush.preview(ctx, width, height)
  return "lua-rendered\npreview frame"
end

function brush.paint(ctx, event)
end

return brush
```

`paint(ctx, event)` owns brush behavior. `preview(ctx, width, height)` returns the text frame shown in the corner preview area; Zig only positions that returned text.

## ownership

the brush owns:

- glyph choices
- number-key meanings
- press/move/release behavior
- staged preview contents
- animation opt-in through `animated = true`
- particle behavior when using `ctx.emit`

Zig owns:

- terminal IO
- canvas/world memory
- particles storage
- selection/copy/paste/move
- visual move overlays
- brush discovery
- event routing
- diff rendering and flushing

Lua brushes are trusted local code. do not install brushes from sources you do not trust.

## coordinates

all coordinates are 1-based terminal cells.

```lua
ctx.set(1, 1, "*")
ctx.emit(10, 5, "·", 2, 0.2, -0.1)
```

use `event.world_x` and `event.world_y` for painting. `event.x` and `event.y` are viewport coordinates.

## drawing

```lua
ctx.set(x, y, glyph)        -- returns true if the cell exists
local glyph = ctx.get(x, y) -- returns " " outside the canvas
ctx.line(x0, y0, x1, y1, glyph)
ctx.fill(x, y, width, height, glyph)
ctx.rect(x, y, width, height, edge_glyph, fill_glyph_or_nil)
ctx.clear()                 -- clears canvas and particles
```

`glyph` is a Lua string. the canvas stores up to 8 UTF-8 bytes per cell. Prefer `line`, `fill`, and `rect` for hot paths: Lua chooses the brush intent, Zig touches cells in bulk.

## staged previews

use the stage for temporary drag previews:

```lua
ctx.stageSet(x, y, glyph)
local staged = ctx.stageGet(x, y)
ctx.stageClear()
ctx.commitStage()
```

staged cells are visible but not permanent until `ctx.commitStage()`.

default behavior:

- `box` and `line` use staged previews while dragging
- release commits the stage
- number keys during a drag should clear and redraw the preview

## particles

spawn:

```lua
ctx.emit(x, y, glyph, ttl, vx, vy)
```

read:

```lua
local ok, x, y, vx, vy, glyph, ttl, age, seed = ctx.getParticle(i)
```

write:

```lua
ctx.setParticle(i, x, y, vx, vy, glyph, ttl)
```

remove:

```lua
ctx.removeParticle(i)
```

iterate:

```lua
ctx.eachParticle(function(i)
  local ok, x, y, vx, vy, glyph, ttl, age, seed = ctx.getParticle(i)
  if not ok then return end

  -- update brush state here
  ctx.setParticle(i, x, y, vx, vy, glyph, ttl)
end)
```

the particle array is owned by Zig. Lua gets stable index handles and reads/writes fields through the boundary instead of allocating a Lua table per particle per frame.

## time and randomness

```lua
local t = ctx.time()
local dt = ctx.dt()
local r = ctx.random()
local v = ctx.randomRange(0, 10)
```

## events

mouse:

```lua
if event.type == "mouse" and event.button == "left" and event.action ~= "release" then
  ctx.emit(event.x, event.y, "*", 3, 0, 0)
end
```

frame:

```lua
if event.type == "frame" then
  ctx.eachParticle(function(i)
    -- update particles
  end)
end
```

paste:

```lua
if event.type == "paste" then
  local x = event.x
  local y = event.y
  local text = event.text
  local positioned = event.positioned
end
```

resize:

```lua
if event.type == "resize" then
  local w = event.width
  local h = event.height
end
```

digit:

```lua
if event.type == "digit" then
  -- works while a drag preview is active
  state.variant = event.digit
end
```

key:

```lua
if event.type == "key" and event.key == "b" then
  -- brush-local behavior
end
```

## animation

by default, brushes are not animated.

a brush gets `frame` events only when:

- the active brush has `animated = true`, or
- live particles exist.

holding the mouse still does not repeatedly call `paint`. if a brush wants continuous behavior while held still, it should track its own held state and opt into frames.

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

## shipped brush controls

- `box`: `1` style, `2` corner, `3` fill, `4` edge pattern, `0` cancel
- `line`: `1` style; styles include horizontal, vertical, diagonal, and reverse-diagonal glyph variants
- `eraser`: `1` larger, `2` smaller
- `seed`, `soil`, `moss`, `floral`: size and glyph palette controls
- `particles`: animated particle burst
