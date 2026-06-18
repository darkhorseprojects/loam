# brush API

a brush is one Lua file that returns a table:

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
  }, "\n")
end

function brush.paint(ctx, event)
  if event.type == "mouse" and event.button == "left" then
    ctx.set(event.world_x, event.world_y, brush.glyph)
  end
end

return brush
```

## brush ownership

the brush owns:

- glyphs
- number-key meanings
- press/move/release behavior
- staged preview contents
- animation opt-in
- particle behavior

Zig owns:

- terminal IO
- canvas/world memory
- particles storage
- selection/copy/paste/move
- brush discovery
- event routing
- rendering and flushing

## ctx drawing

```lua
ctx.set(x, y, glyph)
local glyph = ctx.get(x, y)
ctx.clear()
```

coordinates are 1-based terminal cells.

## stage

the stage is temporary and visible:

```lua
ctx.stageSet(x, y, glyph)
ctx.stageClear()
ctx.commitStage()
```

staged cells become permanent only after `ctx.commitStage()`.

## particles

```lua
ctx.emit(x, y, glyph, ttl, vx, vy)
ctx.eachParticle(function(i)
  local ok, x, y, vx, vy, glyph, ttl, age, seed = ctx.getParticle(i)
end)
```

the particle array is owned by Zig. Lua gets numeric indices instead of per-particle tables.

## events

mouse events include `button`, `action`, `x`, `y`, `world_x`, `world_y`, `dt`, and `time`.

digit events are brush-owned:

```lua
{ type = "digit", digit = 1 }
```

frame events only happen when the active brush has `animated = true` or live particles exist.
