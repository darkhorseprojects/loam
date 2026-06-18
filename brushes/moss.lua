local brush = {
  name = "moss",
  glyph = ",",
}

local radius = 2
local palettes = {
  { name = "ascii", knots = { ",", "'", "." }, fronds = { "`", "." } },
  { name = "lichen", knots = { "⁘", "⁙", "⸬" }, fronds = { "·", "⸱" } },
  { name = "curl", knots = { "❦", "❧", "꩜" }, fronds = { "⌁", "·" } },
  { name = "shade", knots = { "▒", "▓", "░" }, fronds = { "░", "·" } },
}
local palette_i = 1

local function palette()
  return palettes[palette_i]
end

local function occupied(ctx, x, y)
  return ctx.get(x, y) ~= " "
end

local function anchored(ctx, x, y)
  for yy = y - 1, y + 1 do
    for xx = x - 1, x + 1 do
      if not (xx == x and yy == y) and occupied(ctx, xx, yy) then return true end
    end
  end
  return false
end

local function pick(ctx, list)
  return list[math.floor(ctx.randomRange(1, #list + 0.999))]
end

local function tuft(ctx, x, y)
  local p = palette()
  local knot = pick(ctx, p.knots)
  local frond = pick(ctx, p.fronds)
  ctx.set(x, y, knot)
  if ctx.random() < 0.65 then ctx.set(x - 1, y, frond) end
  if ctx.random() < 0.65 then ctx.set(x + 1, y, frond) end
  if ctx.random() < 0.38 then ctx.set(x, y - 1, frond) end
  if ctx.random() < 0.38 then ctx.set(x, y + 1, frond) end
end

local function grow(ctx, x, y)
  for yy = y - radius, y + radius do
    for xx = x - radius, x + radius do
      local d = math.abs(xx - x) + math.abs(yy - y)
      if d <= radius and anchored(ctx, xx, yy) and ctx.random() < 0.16 then
        tuft(ctx, xx, yy)
      end
    end
  end
end

function brush.preview(ctx, width, height)
  local p = palette()
  return table.concat({
    " " .. p.fronds[1] .. p.knots[1] .. p.fronds[1],
    "moss " .. p.name,
    "grows attached",
    "1+ 2- size",
    "3 palette r=" .. tostring(radius),
  }, "\n")
end

function brush.paint(ctx, event)
  if event.type == "digit" then
    if event.digit == 1 then radius = math.min(radius + 1, 7) end
    if event.digit == 2 then radius = math.max(radius - 1, 1) end
    if event.digit == 3 then palette_i = palette_i % #palettes + 1 end
    brush.glyph = palette().knots[1]
    return
  end

  if event.type == "mouse" and event.button == "left" and event.action ~= "release" then
    grow(ctx, event.world_x, event.world_y)
  end
end

return brush
