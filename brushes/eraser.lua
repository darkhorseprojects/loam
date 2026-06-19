local brush = {
  name = "eraser",
  glyph = " ",
}

local radius = 1
local last = nil

local function erase(ctx, x, y)
  for yy = y - radius, y + radius do
    for xx = x - radius, x + radius do
      local dx = xx - x
      local dy = yy - y
      if dx * dx + dy * dy <= radius * radius then ctx.set(xx, yy, " ") end
    end
  end
end

local function line(ctx, x0, y0, x1, y1)
  local dx = math.abs(x1 - x0)
  local sx = x0 < x1 and 1 or -1
  local dy = -math.abs(y1 - y0)
  local sy = y0 < y1 and 1 or -1
  local err = dx + dy
  while true do
    erase(ctx, x0, y0)
    if x0 == x1 and y0 == y1 then return end
    local e2 = 2 * err
    if e2 >= dy then err = err + dy; x0 = x0 + sx end
    if e2 <= dx then err = err + dx; y0 = y0 + sy end
  end
end

function brush.preview(ctx, width, height)
  return table.concat({
    "            ",
    "   erase    ",
    "  radius " .. tostring(radius),
    "[1] bigger ",
    "[2] small [0] reset",
  }, "\n")
end

function brush.paint(ctx, event)
  if event.type == "digit" then
    if event.digit == 0 then radius = 1; last = nil end
    if event.digit == 1 then radius = math.min(radius + 1, 12) end
    if event.digit == 2 then radius = math.max(radius - 1, 1) end
    return
  end

  if event.type ~= "mouse" or event.button ~= "left" then return end
  local x = event.world_x
  local y = event.world_y
  if event.action == "press" then
    erase(ctx, x, y)
    last = { x = x, y = y }
  elseif event.action == "move" and last then
    line(ctx, last.x, last.y, x, y)
    last = { x = x, y = y }
  elseif event.action == "release" then
    if last then line(ctx, last.x, last.y, x, y) end
    last = nil
  end
end

return brush
