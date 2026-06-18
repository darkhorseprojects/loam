local brush = {
  name = "particles",
  glyph = "·",
  animated = true,
}

local glyphs = { "·", ".", "*", "+" }
local glyph_i = 1

local function burst(ctx, x, y, count)
  for i = 1, count do
    ctx.emit(
      x,
      y,
      glyphs[glyph_i],
      ctx.randomRange(0.8, 2.8),
      ctx.randomRange(-1.2, 1.2),
      ctx.randomRange(-1.4, 0.4)
    )
  end
end

function brush.preview(ctx, width, height)
  return table.concat({
    "    " .. glyphs[glyph_i] .. "     ",
    "  . * +  ",
    " burst   ",
    "1 glyph  ",
    "count " .. tostring(ctx.particleCount()),
  }, "\n")
end

function brush.paint(ctx, event)
  if event.type == "digit" then
    if event.digit == 0 then glyph_i = 1 end
    if event.digit == 1 then glyph_i = glyph_i % #glyphs + 1 end
    brush.glyph = glyphs[glyph_i]
  end

  if event.type == "mouse" and event.button == "left" then
    if event.action == "press" then
      burst(ctx, event.world_x, event.world_y, 48)
    elseif event.action == "move" then
      burst(ctx, event.world_x, event.world_y, 8)
    end
  end

  if event.type == "frame" then
    ctx.eachParticle(function(i)
      local ok, x, y, vx, vy, glyph, ttl, age = ctx.getParticle(i)
      if not ok then return end
      age = age + ctx.dt()
      vy = vy + 0.045
      vx = vx * 0.985
      vy = vy * 0.985
      x = x + vx * 9.0 * ctx.dt()
      y = y + vy * 9.0 * ctx.dt()
      if age >= ttl then
        ctx.removeParticle(i)
      else
        ctx.setParticle(i, x, y, vx, vy, glyph, ttl, age)
      end
    end)
  end
end

return brush
