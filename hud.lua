local economy = require "economy"
local ui      = require "ui"

local M       = {}

function M.draw()
  local scale          = 3
  local _, th          = usagi.measure_text("0")
  local bal_y          = 6
  local rate_y         = bal_y + th * scale + 3

  local money_text     = string.format("$%.0f", State.money)
  local cash_rate_text = string.format("%.2f $/sec", economy.ghost_cash_rate())
  local cash_w         = math.max(usagi.measure_text(money_text) * scale,
    usagi.measure_text(cash_rate_text))

  local cash_x         = (usagi.GAME_W - cash_w) / 2

  gfx.text_ex(money_text, cash_x, bal_y, scale, 0, gfx.COLOR_GREEN, 1)

  if State.mode == "race" and State.race and State.race.phase == "racing" then
    local rank       = economy.rank_for_rate(State.active_track, economy.live_race_rate())
    local rank_text  = rank
    local rank_scale = 3
    local rank_w     = usagi.measure_text(rank_text) * rank_scale
    local rank_x     = (usagi.GAME_W - rank_w) / 2
    ui.rank_text(rank_text, rank, rank_x, rate_y, rank_scale)
  end
end

return M
