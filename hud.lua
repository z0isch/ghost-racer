local economy = require "economy"

local M = {}

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

  local show_rates     = economy.owns_any_ghost()

  gfx.text_ex(money_text, cash_x, bal_y, scale, 0, gfx.COLOR_GREEN, 1)
  if show_rates then
    gfx.text_ex(cash_rate_text, cash_x, rate_y, 1, 0, gfx.COLOR_GREEN, 1)
  end
end

return M
