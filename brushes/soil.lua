local brush = {
  name = "soil",
  glyph = "#",
}

local radius = 1
local palettes = {
  { name = "ascii", glyphs = { "#", ":", ".", "." } },
  { name = "grain", glyphs = { "⸱", "·", "∙", ":" } },
  { name = "shade", glyphs = { "░", "▒", "▓", "█" } },
  { name = "stone", glyphs = { "◆", "◇", "◈", "▪" } },
}
local palette_i = 1

local function palette()
  return palettes[palette_i]
end

local function pick(ctx)
  local glyphs = palette().glyphs
  return glyphs[math.floor(ctx.randomRange(1, #glyphs + 0.999))]
end

local function dab(ctx, x, y)
  for yy = y - radius, y + radius do
    for xx = x - radius, x + radius do
      local dx = xx - x
      local dy = yy - y
      if dx * dx + dy * dy <= radius * radius and ctx.random() < 0.58 then
        ctx.set(xx, yy, pick(ctx))
      end
    end
  end
end

function brush.preview(ctx, width, height)
  local p = palette()
  return table.concat({
    " " .. p.glyphs[1] .. p.glyphs[2] .. p.glyphs[3],
    "soil " .. p.name,
    "1+ 2- size",
    "3 palette",
    "r=" .. tostring(radius),
  }, "\n")
end

function brush.paint(ctx, event)
  if event.type == "digit" then
    if event.digit == 0 then radius = 1; palette_i = 1 end
    if event.digit == 1 then radius = math.min(radius + 1, 8) end
    if event.digit == 2 then radius = math.max(radius - 1, 1) end
    if event.digit == 3 then palette_i = palette_i % #palettes + 1 end
    return
  end

  if event.type == "mouse" and event.button == "left" and event.action ~= "release" then
    dab(ctx, event.world_x, event.world_y)
  end
end

return brush
