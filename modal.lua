-- Full-screen modal: dims the scene, then draws a bordered panel with a
-- centered title, body, and a single dismiss button. Immediate-mode; call
-- from _draw. Layout is computed from the measured text, so any number of
-- body lines fits.

local ui           = require "ui"

local TITLE_SCALE  = 3
local BODY_SCALE   = 2
local BUTTON_SCALE = 2
local BUTTON_W     = 180
local BUTTON_PAD_Y = 2 -- matches ui.button's vertical padding
local PANEL_PAD    = 16
local TITLE_Y      = 60
local GAP          = 20 -- vertical space between title, body, and button

local M            = {}

-- Draws the modal. Returns true the frame the button is clicked.
-- opts: title (string), body (string), button (string, default "GOT IT")
function M.draw(opts)
  gfx.rect_fill(0, 0, usagi.GAME_W, usagi.GAME_H, gfx.COLOR_BLACK, .4)

  local title       = opts.title
  local body        = opts.body
  local button      = opts.button or "GOT IT"

  -- measure_text height is the font line height, so multi-line bodies are
  -- sized by counting lines.
  local tw, line_h  = usagi.measure_text(title)
  tw                = tw * TITLE_SCALE
  local bw          = usagi.measure_text(body) * BODY_SCALE
  local _, breaks   = body:gsub("\n", "")
  local bh          = (breaks + 1) * line_h * BODY_SCALE

  local ty          = TITLE_Y
  local by          = ty + line_h * TITLE_SCALE + GAP
  local btn_y       = by + bh + GAP
  local btn_h       = line_h * BUTTON_SCALE + BUTTON_PAD_Y * 2

  local panel_w     = math.max(tw, bw, BUTTON_W) + PANEL_PAD * 2
  local panel_x     = math.floor((usagi.GAME_W - panel_w) / 2)
  local panel_y     = ty - PANEL_PAD
  local panel_h     = (btn_y + btn_h + PANEL_PAD) - panel_y
  gfx.rect_fill(panel_x, panel_y, panel_w, panel_h, gfx.COLOR_DARK_GRAY)
  gfx.rect(panel_x, panel_y, panel_w, panel_h, gfx.COLOR_WHITE)

  local tx = math.floor((usagi.GAME_W - tw) / 2)
  gfx.text_ex(title, tx, ty, TITLE_SCALE, 0, gfx.COLOR_WHITE, 1)

  local bx = math.floor((usagi.GAME_W - bw) / 2)
  gfx.text_ex(body, bx, by, BODY_SCALE, 0, gfx.COLOR_LIGHT_GRAY, 1)

  local btn_x = math.floor((usagi.GAME_W - BUTTON_W) / 2)
  return ui.button(button, btn_x, btn_y, { w = BUTTON_W, scale = BUTTON_SCALE })
end

return M
