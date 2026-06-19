local brush = {
  name = "box",
  glyph = "┌",
}

local styles = {
  { name = "ascii", h = "-", v = "|", tl = "+", tr = "+", bl = "+", br = "+" },
  { name = "thin", h = "─", v = "│", tl = "┌", tr = "┐", bl = "└", br = "┘" },
  { name = "round", h = "─", v = "│", tl = "╭", tr = "╮", bl = "╰", br = "╯" },
  { name = "heavy", h = "━", v = "┃", tl = "┏", tr = "┓", bl = "┗", br = "┛" },
  { name = "double", h = "═", v = "║", tl = "╔", tr = "╗", bl = "╚", br = "╝" },
  { name = "mixed", h = "═", v = "│", tl = "╒", tr = "╕", bl = "╘", br = "╛" },
  { name = "block", h = "▀", v = "█", tl = "█", tr = "█", bl = "█", br = "█" },
}

local corner_sets = {
  { name = "style", glyph = nil },
  { name = "plus", glyph = "+" },
  { name = "dot", glyph = "•" },
  { name = "star", glyph = "✦" },
  { name = "diamond", glyph = "◆" },
  { name = "square", glyph = "■" },
}

local fills = { " ", ".", "·", "░", "▒", "▓", "█" }
local patterns = {
  { name = "solid", glyphs = nil },
  { name = "dash", glyphs = { false, false, " ", " " } },
  { name = "dot", glyphs = { "·", " ", "·", " " } },
  { name = "bead", glyphs = { false, "•", false, "·" } },
}

local state = {
  style = 2,
  corner = 1,
  fill = 1,
  pattern = 1,
  drag = nil,
  last = nil,
}

local function style() return styles[state.style] end
local function fill() return fills[state.fill] end
local function pattern() return patterns[state.pattern] end

local function corner(which)
  local override = corner_sets[state.corner].glyph
  if override then return override end
  return style()[which]
end

local function mark(ctx, x, y, glyph, staged)
  if glyph == " " then return end
  if staged then ctx.stageSet(x, y, glyph) else ctx.set(x, y, glyph) end
end

local function edge_glyph(step, fallback)
  local glyphs = pattern().glyphs
  if not glyphs then return fallback end
  local glyph = glyphs[(step % #glyphs) + 1]
  if glyph == false then return fallback end
  return glyph
end

local function draw_box(ctx, x0, y0, x1, y1, staged)
  if x0 > x1 then x0, x1 = x1, x0 end
  if y0 > y1 then y0, y1 = y1, y0 end
  x0 = math.floor(x0); y0 = math.floor(y0); x1 = math.floor(x1); y1 = math.floor(y1)

  local s = style()
  local f = fill()
  if f ~= " " and x1 - x0 > 1 and y1 - y0 > 1 then
    for y = y0 + 1, y1 - 1 do
      for x = x0 + 1, x1 - 1 do mark(ctx, x, y, f, staged) end
    end
  end

  for x = x0, x1 do
    local step = x - x0
    mark(ctx, x, y0, edge_glyph(step, s.h), staged)
    mark(ctx, x, y1, edge_glyph(step, s.h), staged)
  end
  for y = y0, y1 do
    local step = y - y0
    mark(ctx, x0, y, edge_glyph(step, s.v), staged)
    mark(ctx, x1, y, edge_glyph(step, s.v), staged)
  end

  mark(ctx, x0, y0, corner("tl"), staged)
  mark(ctx, x1, y0, corner("tr"), staged)
  mark(ctx, x0, y1, corner("bl"), staged)
  mark(ctx, x1, y1, corner("br"), staged)
end

local function draw_preview(ctx, x, y)
  ctx.stageClear()
  if state.drag then draw_box(ctx, state.drag.x, state.drag.y, x, y, true) end
end

local function apply_digit(ctx, digit)
  if digit == 1 then
    state.style = state.style % #styles + 1
  elseif digit == 2 then
    state.corner = state.corner % #corner_sets + 1
  elseif digit == 3 then
    state.fill = state.fill % #fills + 1
  elseif digit == 4 then
    state.pattern = state.pattern % #patterns + 1
  elseif digit == 0 then
    state.style = 2
    state.corner = 1
    state.fill = 1
    state.pattern = 1
    state.drag = nil
    state.last = nil
    ctx.stageClear()
  end
end

function brush.preview(ctx, width, height)
  local s = style()
  local inner = math.max(width - 2, 1)
  local function row(text)
    text = text:sub(1, inner)
    return s.v .. text .. string.rep(" ", inner - #text) .. s.v
  end
  local top = ""
  local bottom = ""
  for i = 0, inner - 1 do
    top = top .. edge_glyph(i, s.h)
    bottom = bottom .. edge_glyph(i, s.h)
  end
  return table.concat({
    corner("tl") .. top .. corner("tr"),
    row("box " .. s.name .. " [0]"),
    row("[1] style [2] " .. corner_sets[state.corner].name),
    row("[3] fill " .. fill() .. " [4] " .. pattern().name),
    corner("bl") .. bottom .. corner("br"),
  }, "\n")
end

function brush.paint(ctx, event)
  if event.type == "digit" then
    apply_digit(ctx, event.digit)
    if state.drag and state.last then draw_preview(ctx, state.last.x, state.last.y) end
    return
  end
  if event.type ~= "mouse" or event.button ~= "left" then return end

  local x = event.world_x
  local y = event.world_y
  if event.action == "press" then
    state.drag = { x = x, y = y }
    state.last = { x = x, y = y }
    draw_preview(ctx, x, y)
  elseif event.action == "move" and state.drag then
    state.last = { x = x, y = y }
    draw_preview(ctx, x, y)
  elseif event.action == "release" and state.drag then
    draw_preview(ctx, x, y)
    ctx.commitStage()
    state.drag = nil
    state.last = nil
    ctx.stageClear()
  end
end

return brush
