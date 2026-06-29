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
    local scale = p.ghost and 1 or 2
    local alpha = (1 - t) * (p.ghost and 0.6 or 1) * (p.alpha_mul or 1)
    local py    = p.y - t * CASH_POP_RISE
    local color = gfx.COLOR_GREEN
    if p.currency == "coin" then color = gfx.COLOR_YELLOW end
    local text = string.format("%.0f", p.amount)
    local tw   = usagi.measure_text(text) * scale
    local px   = math.floor(p.x - tw / 2)
    gfx.text_ex(text, px, py, scale, 0, color, alpha)
  end
end

return M
