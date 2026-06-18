local brush = {
  name = "floral",
  glyph = "✿",
}

local radius = 1
local palettes = {
  { name = "ascii", centers = { "*", "o", "+" }, petals = { ".", "'" } },
  { name = "garden", centers = { "✿", "❀", "❁" }, petals = { "·", "✧" } },
  { name = "sakura", centers = { "🌸", "❀", "✿" }, petals = { "·", "❊" } },
  { name = "wild", centers = { "✾", "❋", "✺" }, petals = { "✧", "·" } },
}
local palette_i = 2

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

local function flower(ctx, x, y)
  local p = palette()
  local c = pick(ctx, p.centers)
  local petal = pick(ctx, p.petals)
  ctx.set(x, y, c)
  if ctx.random() < 0.70 then ctx.set(x - 1, y, petal) end
  if ctx.random() < 0.70 then ctx.set(x + 1, y, petal) end
  if ctx.random() < 0.50 then ctx.set(x, y - 1, petal) end
  if ctx.random() < 0.50 then ctx.set(x, y + 1, petal) end
end

local function draw(ctx, x, y)
  for yy = y - radius, y + radius do
    for xx = x - radius, x + radius do
      local d = math.abs(xx - x) + math.abs(yy - y)
      if d <= radius and anchored(ctx, xx, yy) and ctx.random() < 0.10 then
        flower(ctx, xx, yy)
      end
    end
  end
end

function brush.preview(ctx, width, height)
  local p = palette()
  return table.concat({
    " " .. p.petals[1] .. p.centers[1] .. p.petals[1],
    "floral " .. p.name,
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
    return
  end

  if event.type == "mouse" and event.button == "left" and event.action ~= "release" then
    draw(ctx, event.world_x, event.world_y)
  end
end

return brush
