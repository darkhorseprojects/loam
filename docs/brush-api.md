# brush api

A brush is one Lua file. It returns a table.

```lua
local brush = {
  name = "brush name",
  glyph = "*",
  animated = false,
}

function brush.preview(ctx, width, height)
  return "preview text"
end

function brush.paint(ctx, event)
end

return brush
```

## coordinates

Coordinates are 1-based cells. Use `event.world_x` / `event.world_y` for painting.

## ctx

```lua
ctx.set(x, y, glyph)
ctx.get(x, y)
ctx.line(x0, y0, x1, y1, glyph)
ctx.fill(x, y, width, height, glyph)
ctx.rect(x, y, width, height, edge, fill_or_nil)
ctx.stageSet(x, y, glyph)
ctx.stageClear()
ctx.commitStage()
ctx.clear()
ctx.requestText(label)
ctx.emit(x, y, glyph, ttl, vx, vy)
ctx.particleCount()
ctx.getParticle(i)
ctx.setParticle(i, x, y, vx, vy, glyph, ttl, age)
ctx.removeParticle(i)
ctx.eachParticle(fn)
ctx.time()
ctx.dt()
ctx.random()
ctx.randomRange(a, b)
```

Glyphs are Lua strings. A cell stores up to 8 UTF-8 bytes.

## events

Mouse:

```lua
{
  type = "mouse",
  button = "left",
  action = "press",
  x = 1,
  y = 1,
  world_x = 1,
  world_y = 1,
}
```

Digit:

```lua
{ type = "digit", digit = 1 }
```

Paste:

```lua
{ type = "paste", x = 1, y = 1, text = "..." }
```

Frame:

```lua
{ type = "frame", dt = 0.016, time = 12.34 }
```

Text capture:

```lua
ctx.requestText("text")

{ type = "text", action = "input", text = "a" }
{ type = "text", action = "backspace", text = "" }
{ type = "text", action = "submit", text = "typed text" }
{ type = "text", action = "cancel", text = "typed text" }
```

Lua never reads terminal input directly.

## shipped brush controls

- `0`: reset bundled brush state
- `box`: `1` style, `2` corner, `3` fill, `4` edge pattern
- `line`: `1` style
- `eraser`: `1` larger, `2` smaller
- `soil`: `1` larger, `2` smaller, `3` palette
- `moss`, `floral`: `1` larger, `2` smaller, `3` palette
- `text`: `1` larger text mode, `2` smaller text mode
- `particles`: `1` glyph

## animation

Set `animated = true` to receive `frame` events. Live particles also keep frame events running.
