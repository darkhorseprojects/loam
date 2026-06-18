local brush = {
  name = "line",
  glyph = "─",
}

local styles = {
  { name = "ascii", h = { "-" }, v = { "|" }, d = "/", b = "\\" },
  { name = "thin", h = { "─" }, v = { "│" }, d = "╱", b = "╲" },
  { name = "heavy", h = { "━" }, v = { "┃" }, d = "╱", b = "╲" },
  { name = "double", h = { "═" }, v = { "║" }, d = "╱", b = "╲" },
  { name = "dashed", h = { "╌", "╌", " ", "╌" }, v = { "╎", "╎", " ", "╎" }, d = "╱", b = "╲" },
  { name = "rail", h = { "╼", "─", "─", "╾" }, v = { "╿", "│", "│", "╽" }, d = "╱", b = "╲" },
  { name = "bead", h = { "─", "•", "─", "·" }, v = { "│", "•", "│", "·" }, d = "╱", b = "╲" },
  { name = "spark", h = { "─", "✦", "─", "✧" }, v = { "│", "✦", "│", "✧" }, d = "╱", b = "╲" },
  { name = "dotted", h = { "·", "⸱", "·", " " }, v = { "·", "⸱", "·", " " }, d = "╱", b = "╲" },
  { name = "shade", h = { "░", "▒", "▓", "▒" }, v = { "░", "▒", "▓", "▒" }, d = "╱", b = "╲" },
  { name = "block", h = { "▀", "█", "▄", "█" }, v = { "▌", "█", "▐", "█" }, d = "╱", b = "╲" },
  { name = "wave", h = { "~", "≈", "~", "⌁" }, v = { "╎", "╏", "╎", "╏" }, d = "╱", b = "╲" },
  { name = "slant", h = { "╱", "╲", "╱", "╲" }, v = { "╱", "╲", "╱", "╲" }, d = "╱", b = "╲" },
}
local style_i = 2
local drag = nil

local function style()
  return styles[style_i]
end

local function pick(list, step)
  if type(list) == "string" then return list end
  return list[(step % #list) + 1]
end

local function glyph_at(step, vertical, diagonal, sx, sy)
  local s = style()
  if vertical then return pick(s.v, step) end
  if diagonal then return sx == sy and pick(s.b, step) or pick(s.d, step) end
  return pick(s.h, step)
end

local function preview_pattern()
  local s = style()
  return pick(s.h, 0) .. pick(s.h, 1) .. pick(s.h, 2) .. pick(s.h, 3) .. pick(s.v, 0) .. pick(s.v, 1)
end

local function draw(ctx, x0, y0, x1, y1, staged)
  local dx = math.abs(x1 - x0)
  local dy_abs = math.abs(y1 - y0)
  local sx = x0 < x1 and 1 or -1
  local dy = -dy_abs
  local sy = y0 < y1 and 1 or -1
  local err = dx + dy
  local step = 0
  local vertical = dx == 0
  local diagonal = dx ~= 0 and dy_abs ~= 0
  while true do
    local glyph = glyph_at(step, vertical, diagonal, sx, sy)
    if glyph ~= " " then
      if staged then ctx.stageSet(x0, y0, glyph) else ctx.set(x0, y0, glyph) end
    end
    if x0 == x1 and y0 == y1 then return end
    local e2 = 2 * err
    if e2 >= dy then err = err + dy; x0 = x0 + sx end
    if e2 <= dx then err = err + dx; y0 = y0 + sy end
    step = step + 1
  end
end

local function preview_line(ctx, x, y)
  ctx.stageClear()
  if drag then draw(ctx, drag.x, drag.y, x, y, true) end
end

function brush.preview(ctx, width, height)
  local s = style()
  return table.concat({
    preview_pattern(),
    "line " .. s.name,
    "1 style",
    "h/v/diag",
    "release set",
  }, "\n")
end

function brush.paint(ctx, event)
  if event.type == "digit" and event.digit == 1 then
    style_i = style_i % #styles + 1
    brush.glyph = pick(style().h, 0)
    if drag then preview_line(ctx, drag.last_x or drag.x, drag.last_y or drag.y) end
    return
  end

  if event.type ~= "mouse" or event.button ~= "left" then return end
  local x = event.world_x
  local y = event.world_y
  if event.action == "press" then
    drag = { x = x, y = y, last_x = x, last_y = y }
    preview_line(ctx, x, y)
  elseif event.action == "move" and drag then
    drag.last_x = x
    drag.last_y = y
    preview_line(ctx, x, y)
  elseif event.action == "release" and drag then
    preview_line(ctx, x, y)
    ctx.commitStage()
    ctx.stageClear()
    drag = nil
  end
end

return brush
