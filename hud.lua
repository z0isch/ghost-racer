local economy = require "economy"
local ui      = require "ui"

local M       = {}

function M.draw()
  local scale        = 3
  local _, th        = usagi.measure_text("0")
  local bal_y        = 6
  local total_rate_y = bal_y + th * scale + 3
  local rate_y       = total_rate_y

  local money_text   = string.format("$%.0f", State.money)
  local cash_w       = usagi.measure_text(money_text) * scale
  local cash_x       = (usagi.GAME_W - cash_w) / 2

  gfx.text_ex(money_text, cash_x, bal_y, scale, 0, gfx.COLOR_GREEN, 1)

  if economy.owns_any_ghost() then
    local total_rate_text = string.format("$%.1f/sec", economy.ghost_cash_rate())
    local total_rate_w    = usagi.measure_text(total_rate_text)
    local total_rate_x    = (usagi.GAME_W - total_rate_w) / 2
    gfx.text_ex(total_rate_text, total_rate_x, total_rate_y, 1, 0, gfx.COLOR_LIGHT_GRAY, 1)
    rate_y = rate_y + th + 4
  end

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
