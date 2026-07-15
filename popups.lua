local CASH_POP_LIFE = 1.5
local CASH_POP_RISE = 50

local cash_pops = {}

local M = {}

function M.spawn(p)
  p.age = 0
  cash_pops[#cash_pops + 1] = p
end

function M.clear()
  cash_pops = {}
end

function M.update(dt)
  local i = 1
  while i <= #cash_pops do
    cash_pops[i].age = cash_pops[i].age + dt
    if cash_pops[i].age > CASH_POP_LIFE then
      table.remove(cash_pops, i)
    else
      i = i + 1
    end
  end
end

function M.draw()
  for _, p in ipairs(cash_pops) do
    local t     = p.age / CASH_POP_LIFE
    local scale = p.ghost and 2 or 3
    local alpha = (1 - t) * (p.ghost and 0.6 or 1) * (p.alpha_mul or 1)
    local py    = p.y - t * CASH_POP_RISE
    local text  = string.format("$%.0f", p.amount)
    local tw    = usagi.measure_text(text) * scale
    local px    = math.floor(p.x - tw / 2)
    -- seed the wiggle with spawn position so pops don't wobble in unison
    local rot   = math.sin(usagi.elapsed * 6 + p.x) * 0.08
    gfx.text_ex(text, px + 1, py + 1, scale, rot, gfx.COLOR_BLACK, alpha)
    gfx.text_ex(text, px, py, scale, rot, gfx.COLOR_GREEN, alpha)
  end
end

return M
