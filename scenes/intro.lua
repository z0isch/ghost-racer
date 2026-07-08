local ui         = require "ui"
local road       = require "road"
local track_data = require "track_data"

local M          = {}

function M.enter()
end

function M.exit()
end

function M.update(dt)
end

function M.draw()
  local title = "Ghost Loop"
  gfx.rect_fill(0, 0, usagi.GAME_W, usagi.GAME_H, gfx.COLOR_BLACK)
  local scale      = 5
  local tw         = usagi.measure_text(title) * scale
  local _, th      = usagi.measure_text(title)
  local tx         = math.floor((usagi.GAME_W - tw) / 2)
  local ty         = math.floor(usagi.GAME_H / 3 - th * scale / 2)

  local wave_amp   = 10
  local wave_speed = 4
  local wave_gap   = 0.5
  local cx         = tx
  for i = 1, #title do
    local ch = title:sub(i, i)
    local cw = usagi.measure_text(ch) * scale
    local cy = ty + math.floor(wave_amp * math.sin(usagi.elapsed * wave_speed + i * wave_gap))
    gfx.text_ex(ch, cx, cy, scale, 0, gfx.COLOR_INDIGO, 1)
    cx = cx + cw
  end

  if State.loop >= 2 then
    local tag = "LOOP " .. State.loop
    local tw2 = usagi.measure_text(tag) * 2
    gfx.text_ex(tag, math.floor((usagi.GAME_W - tw2) / 2), ty + th * scale + 12, 2, 0, gfx.COLOR_INDIGO, 1)
  end

  local w      = 200
  local race_x = math.floor((usagi.GAME_W - w) / 2)
  if ui.button("RACE", race_x, usagi.GAME_H - 120, { w = w, scale = 3 }) then
    SceneGoto("race")
  end
end

return M
