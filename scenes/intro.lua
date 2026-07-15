local ui         = require "ui"
local road       = require "road"
local track_data = require "track_data"
local car        = require "car"

local M          = {}

function M.enter()
  -- Guarantees engine silence on every path in, including dev live-reload
  -- and Reset, which keep the music channel playing across _init.
  car.stop_engine(State.car)
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

  ui.neon_text(title, tx, ty, scale, {
    shadow = gfx.COLOR_DARK_PURPLE,
    wave_amp = 10,
    wave_speed = 4,
    wave_phase = 0.5,
  })

  if State.loop >= 2 then
    local tag = "LOOP " .. State.loop
    local tw2 = usagi.measure_text(tag) * 2
    ui.neon_text(tag, math.floor((usagi.GAME_W - tw2) / 2), ty + th * scale + 12, 2, {
      colors = { gfx.COLOR_LIGHT_GRAY },
      shadow = gfx.COLOR_DARK_PURPLE,
    })
  end

  local w      = 200
  local race_x = math.floor((usagi.GAME_W - w) / 2)
  if ui.button("RACE", race_x, usagi.GAME_H - 120, { w = w, scale = 3 }) then
    SceneGoto("race")
  end
end

return M
