local brush = {
  name = "seed",
  glyph = ".",
}

local radius = 1
local palettes = {
  { name = "plain", glyphs = { ".", ".", "'", "`" } },
  { name = "sprout", glyphs = { ".", "'", "˱", "˲", "ꜛ" } },
  { name = "petal", glyphs = { "·", "✦", "✧", "❊" } },
  { name = "sakura", glyphs = { "🌸", "❀", "✿", "·" } },
  { name = "leaf", glyphs = { "🍃", "❦", "❧", "⌁" } },
}
local palette_i = 1

local function palette()
  return palettes[palette_i]
end

local function pick(ctx)
  local glyphs = palette().glyphs
  return glyphs[math.floor(ctx.randomRange(1, #glyphs + 0.999))]
end

local function paint_text(ctx, x, y, text)
  local cx = x
  local cy = y
  for i = 1, #text do
    local ch = text:sub(i, i)
    if ch == "\n" then
      cx = x
      cy = cy + 1
    else
      ctx.set(cx, cy, ch)
      cx = cx + 1
    end
  end
end

local function scatter(ctx, x, y)
  for yy = y - radius, y + radius do
    for xx = x - radius, x + radius do
      if math.abs(xx - x) + math.abs(yy - y) <= radius and ctx.random() < 0.34 then
        ctx.set(xx, yy, pick(ctx))
      end
    end
  end
end

function brush.preview(ctx, width, height)
  local p = palette()
  return table.concat({
    " " .. p.glyphs[1] .. " " .. p.glyphs[2] .. " " .. p.glyphs[3],
    "seed " .. p.name,
    "1+ 2- size",
    "3 palette",
    "r=" .. tostring(radius),
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
    scatter(ctx, event.world_x, event.world_y)
  end

  if event.type == "paste" then
    paint_text(ctx, event.world_x, event.world_y, event.text or "")
  end
end

return brush
