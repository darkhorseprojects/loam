local brush = {
  name = "moss",
  glyph = ",",
}

local radius = 1
local palettes = {
  { name = "ascii", glyphs = { ",", "'", ".", "`" } },
  { name = "lichen", glyphs = { "·", "⁘", "⁙", "⸬" } },
  { name = "curl", glyphs = { "❦", "❧", "⌁", "꩜" } },
  { name = "shade", glyphs = { "░", "▒", "▓", "·" } },
}
local palette_i = 1

local function palette()
  return palettes[palette_i]
end

local function occupied(ctx, x, y)
  return ctx.get(x, y) ~= " "
end

local function near_growth(ctx, x, y)
  for yy = y - 1, y + 1 do
    for xx = x - 1, x + 1 do
      if not (xx == x and yy == y) and occupied(ctx, xx, yy) then return true end
    end
  end
  return false
end

local function pick(ctx)
  local glyphs = palette().glyphs
  return glyphs[math.floor(ctx.randomRange(1, #glyphs + 0.999))]
end

local function dab(ctx, x, y, strong)
  for yy = y - radius, y + radius do
    for xx = x - radius, x + radius do
      local d = math.abs(xx - x) + math.abs(yy - y)
      if d <= radius and near_growth(ctx, xx, yy) then
        local chance = strong and 0.84 or 0.72
        if ctx.random() < chance then ctx.set(xx, yy, pick(ctx)) end
      end
    end
  end
end

function brush.preview(ctx, width, height)
  local p = palette()
  return table.concat({
    " " .. p.glyphs[1] .. p.glyphs[2] .. p.glyphs[3],
    "moss " .. p.name,
    "attaches only",
    "1+ 2- size",
    "3 palette r=" .. tostring(radius),
  }, "\n")
end

function brush.paint(ctx, event)
  if event.type == "digit" then
    if event.digit == 1 then radius = math.min(radius + 1, 6) end
    if event.digit == 2 then radius = math.max(radius - 1, 1) end
    if event.digit == 3 then palette_i = palette_i % #palettes + 1 end
    return
  end

  if event.type == "mouse" and event.button == "left" and event.action ~= "release" then
    dab(ctx, event.world_x, event.world_y, event.action == "press")
  end
end

return brush
