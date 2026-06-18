local brush = {
  name = "text",
  glyph = "T",
}

local modes = {
  { name = "plain", glyph = nil },
  { name = "block", glyph = "█" },
  { name = "dot", glyph = "•" },
}
local mode_i = 1
local typing = nil

local font = {
  A = { " X ", "X X", "XXX", "X X", "X X" },
  B = { "XX ", "X X", "XX ", "X X", "XX " },
  C = { " XX", "X  ", "X  ", "X  ", " XX" },
  D = { "XX ", "X X", "X X", "X X", "XX " },
  E = { "XXX", "X  ", "XX ", "X  ", "XXX" },
  F = { "XXX", "X  ", "XX ", "X  ", "X  " },
  G = { " XX", "X  ", "X X", "X X", " XX" },
  H = { "X X", "X X", "XXX", "X X", "X X" },
  I = { "XXX", " X ", " X ", " X ", "XXX" },
  J = { "  X", "  X", "  X", "X X", " X " },
  K = { "X X", "X X", "XX ", "X X", "X X" },
  L = { "X  ", "X  ", "X  ", "X  ", "XXX" },
  M = { "X X", "XXX", "XXX", "X X", "X X" },
  N = { "X X", "XXX", "XXX", "XXX", "X X" },
  O = { " X ", "X X", "X X", "X X", " X " },
  P = { "XX ", "X X", "XX ", "X  ", "X  " },
  Q = { " X ", "X X", "X X", "XXX", "  X" },
  R = { "XX ", "X X", "XX ", "X X", "X X" },
  S = { " XX", "X  ", " X ", "  X", "XX " },
  T = { "XXX", " X ", " X ", " X ", " X " },
  U = { "X X", "X X", "X X", "X X", "XXX" },
  V = { "X X", "X X", "X X", "X X", " X " },
  W = { "X X", "X X", "XXX", "XXX", "X X" },
  X = { "X X", "X X", " X ", "X X", "X X" },
  Y = { "X X", "X X", " X ", " X ", " X " },
  Z = { "XXX", "  X", " X ", "X  ", "XXX" },
  ["0"] = { " X ", "X X", "X X", "X X", " X " },
  ["1"] = { " X ", "XX ", " X ", " X ", "XXX" },
  ["2"] = { "XX ", "  X", " X ", "X  ", "XXX" },
  ["3"] = { "XX ", "  X", " X ", "  X", "XX " },
  ["4"] = { "X X", "X X", "XXX", "  X", "  X" },
  ["5"] = { "XXX", "X  ", "XX ", "  X", "XX " },
  ["6"] = { " XX", "X  ", "XX ", "X X", " X " },
  ["7"] = { "XXX", "  X", " X ", " X ", " X " },
  ["8"] = { " X ", "X X", " X ", "X X", " X " },
  ["9"] = { " X ", "X X", " XX", "  X", "XX " },
  ["!"] = { " X ", " X ", " X ", "   ", " X " },
  ["?"] = { "XX ", "  X", " X ", "   ", " X " },
  ["."] = { "   ", "   ", "   ", "   ", " X " },
  [","] = { "   ", "   ", "   ", " X ", "X  " },
  ["-"] = { "   ", "   ", "XXX", "   ", "   " },
  ["+"] = { "   ", " X ", "XXX", " X ", "   " },
  ["/"] = { "  X", "  X", " X ", "X  ", "X  " },
  [" "] = { "   ", "   ", "   ", "   ", "   " },
}

local function reset(ctx)
  mode_i = 1
  typing = nil
  ctx.overlayClear()
end

local function mode()
  return modes[mode_i]
end

local function advance_for(ch)
  if mode_i == 1 then return 1 end
  if ch == " " then return 2 end
  return 4
end

local function cursor(ctx)
  ctx.overlayClear()
  if not typing then return end
  if mode_i == 1 then
    ctx.overlaySet(typing.x, typing.y, "█")
  else
    for row = 0, 4 do ctx.overlaySet(typing.x, typing.y + row, "█") end
  end
end

local function draw_big(ctx, x, y, ch)
  local rows = font[string.upper(ch)] or font["?"]
  local glyph = mode().glyph
  for yy = 1, #rows do
    local row = rows[yy]
    for xx = 1, #row do
      if row:sub(xx, xx) == "X" then ctx.set(x + xx - 1, y + yy - 1, glyph) end
    end
  end
end

local function clear_rect(ctx, rect)
  for yy = rect.y, rect.y + rect.h - 1 do
    for xx = rect.x, rect.x + rect.w - 1 do ctx.set(xx, yy, " ") end
  end
end

local function place(ctx, ch)
  if not typing then return end
  local x = typing.x
  local y = typing.y
  local w = advance_for(ch)
  if mode_i == 1 then
    ctx.set(x, y, ch)
    table.insert(typing.placed, { x = x, y = y, w = 1, h = 1 })
  else
    draw_big(ctx, x, y, ch)
    table.insert(typing.placed, { x = x, y = y, w = w, h = 5 })
  end
  typing.x = typing.x + w
  cursor(ctx)
end

local function backspace(ctx)
  if not typing or #typing.placed == 0 then cursor(ctx); return end
  local rect = table.remove(typing.placed)
  clear_rect(ctx, rect)
  typing.x = rect.x
  typing.y = rect.y
  cursor(ctx)
end

function brush.preview(ctx, width, height)
  local m = mode()
  return table.concat({
    "T text " .. m.name,
    "click then type",
    "enter commit",
    "esc cancel",
    "1+ 2- 0 reset",
  }, "\n")
end

function brush.paint(ctx, event)
  if event.type == "digit" then
    if event.digit == 0 then reset(ctx); return end
    if event.digit == 1 then mode_i = math.min(mode_i + 1, #modes) end
    if event.digit == 2 then mode_i = math.max(mode_i - 1, 1) end
    cursor(ctx)
    return
  end

  if event.type == "mouse" and event.button == "left" and event.action == "press" then
    typing = { x = event.world_x, y = event.world_y, placed = {} }
    cursor(ctx)
    ctx.requestText("text")
    return
  end

  if event.type == "text" then
    if event.action == "input" then place(ctx, event.text) end
    if event.action == "backspace" then backspace(ctx) end
    if event.action == "submit" or event.action == "cancel" then
      typing = nil
      ctx.overlayClear()
    end
  end
end

return brush
