local economy = require "economy"

local M = {}

function M.draw()
  local scale          = 2
  local _, th          = usagi.measure_text("0")
  local bal_y          = 6
  local rate_y         = bal_y + th * scale + 3
  local gap            = 24

  local money_text     = string.format("$%.0f", State.money)
  local cash_rate_text = string.format("%.2f $/sec", economy.ghost_cash_rate())
  local cash_w         = math.max(usagi.measure_text(money_text) * scale,
    usagi.measure_text(cash_rate_text))

  local coin_icon      = economy.COIN_ICON
  local coin_text      = string.format(coin_icon .. "%.0f", State.coins)
  local coin_rate_text = string.format("%.2f " .. coin_icon .. "/sec", economy.ghost_coin_rate())
  local coin_w         = math.max(usagi.measure_text(coin_text) * scale,
    usagi.measure_text(coin_rate_text))

  local cash_x         = (usagi.GAME_W - (cash_w + gap + coin_w)) / 2
  local coin_x         = cash_x + cash_w + gap

  gfx.text_ex(money_text, cash_x, bal_y, scale, 0, gfx.COLOR_GREEN, 1)
  gfx.text_ex(cash_rate_text, cash_x, rate_y, 1, 0, gfx.COLOR_GREEN, 1)
  gfx.text_ex(coin_text, coin_x, bal_y, scale, 0, gfx.COLOR_YELLOW, 1)
  gfx.text_ex(coin_rate_text, coin_x, rate_y, 1, 0, gfx.COLOR_YELLOW, 1)
end

return M
