local brush = {
  name = "seed",
  glyph = ".",
  animated = true,
}

local sprout = { ".", "'", "˱", "˲", "ꜛ" }
local last_x = nil
local last_y = nil

local function cell(v)
  return math.floor(v) + 1
end

local function emit_seed(ctx, x, y)
  ctx.emit(
    x,
    y,
    sprout[1],
    ctx.randomRange(0.9, 1.8),
    ctx.randomRange(-0.05, 0.05),
    ctx.randomRange(-0.10, 0.02)
  )
end

local function plant(ctx, x, y, strong)
  local count = strong and 5 or 2
  for i = 1, count do
    emit_seed(ctx, x + ctx.randomRange(-0.8, 0.8), y + ctx.randomRange(-0.35, 0.35))
  end
end

function brush.preview(ctx, width, height)
  return table.concat({
    " . ' ˱",
    "seed sprout",
    "animated",
    "plant only",
    "live " .. tostring(ctx.particleCount()),
  }, "\n")
end

function brush.paint(ctx, event)
  if event.type == "digit" and event.digit == 0 then
    last_x = nil
    last_y = nil
    return
  end

  if event.type == "mouse" and event.button == "left" then
    if event.action == "press" then
      last_x = event.world_x
      last_y = event.world_y
      plant(ctx, event.world_x, event.world_y, true)
    elseif event.action == "move" then
      local dx = last_x and math.abs(event.world_x - last_x) or 99
      local dy = last_y and math.abs(event.world_y - last_y) or 99
      if dx + dy >= 1 then
        last_x = event.world_x
        last_y = event.world_y
        plant(ctx, event.world_x, event.world_y, false)
      end
    elseif event.action == "release" then
      last_x = nil
      last_y = nil
    end
  end

  if event.type == "frame" then
    ctx.eachParticle(function(i)
      local ok, x, y, vx, vy, glyph, ttl, age = ctx.getParticle(i)
      if not ok then return end
      age = age + ctx.dt()
      local phase = math.min(1, age / ttl)
      local glyph_i = math.min(#sprout, math.floor(phase * #sprout) + 1)
      local next_glyph = sprout[glyph_i]
      x = x + vx * ctx.dt()
      y = y + vy * ctx.dt()
      if age >= ttl then
        ctx.set(cell(x), cell(y), sprout[#sprout])
        ctx.removeParticle(i)
      else
        ctx.setParticle(i, x, y, vx * 0.96, vy * 0.96, next_glyph, ttl, age)
      end
    end)
  end
end

return brush
