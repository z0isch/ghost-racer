local ui             = require "ui"

local CASH_POP_LIFE  = 1.5
local CASH_POP_RISE  = 50

-- Rank-up badge: a small translucent panel over the car holding just the newly
-- reached rank letter, in its rank color. Only ever spawned on a climb (race.lua
-- only fires it above the best rank shown so far), so it always reads as a win.
local RANK_POP_LIFE  = 1.2
local RANK_POP_RISE  = 34
local RANK_POP_SCALE = 2
local RANK_POP_PAD   = 2

local cash_pops      = {}
local rank_pops      = {}

local M              = {}

function M.spawn(p)
  p.age = 0
  cash_pops[#cash_pops + 1] = p
end

-- p: { rank = "C", x, y } -- x is the badge's center, y its bottom edge (the
-- car's top), so the panel sits above the car and rises off it.
function M.spawn_rank(p)
  p.age = 0
  rank_pops[#rank_pops + 1] = p
end

function M.clear()
  cash_pops = {}
  rank_pops = {}
end

local function age_pops(pops, dt, life)
  local i = 1
  while i <= #pops do
    pops[i].age = pops[i].age + dt
    if pops[i].age > life then
      table.remove(pops, i)
    else
      i = i + 1
    end
  end
end

function M.update(dt)
  age_pops(cash_pops, dt, CASH_POP_LIFE)
  age_pops(rank_pops, dt, RANK_POP_LIFE)
end

-- One rank badge: a panel just big enough for the letter, drawn in the rank
-- color (S shimmers through the rainbow, same as the meter's zones). The whole
-- badge shares one alpha -- held solid for the first half of its life, then
-- fading out -- so the car is never hidden behind it for long.
local function draw_rank_pop(p)
  local t      = p.age / RANK_POP_LIFE
  local alpha  = math.min(1, (1 - t) * 2)
  local rw, rh = usagi.measure_text(p.rank)
  rw           = rw * RANK_POP_SCALE
  rh           = rh * RANK_POP_SCALE
  local w      = rw + RANK_POP_PAD * 2
  local h      = rh + RANK_POP_PAD * 2
  local x      = math.floor(p.x - w / 2)
  local y      = math.floor(p.y - t * RANK_POP_RISE - h)

  gfx.rect_fill(x, y, w, h, gfx.COLOR_BLACK, 0.45 * alpha)
  gfx.rect(x, y, w, h, gfx.COLOR_WHITE, 0.35 * alpha)
  local rx = x + RANK_POP_PAD
  local ry = y + RANK_POP_PAD
  gfx.text_ex(p.rank, rx + 1, ry + 1, RANK_POP_SCALE, 0, gfx.COLOR_BLACK, alpha)
  gfx.text_ex(p.rank, rx, ry, RANK_POP_SCALE, 0, ui.rank_color(p.rank, 0), alpha)
end

function M.draw()
  for _, p in ipairs(rank_pops) do
    draw_rank_pop(p)
  end
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
