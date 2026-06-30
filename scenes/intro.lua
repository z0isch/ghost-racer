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
  local tdata = track_data.TRACKS[State.active_track]
  road.draw_track(tdata.map)

  local title  = "Ghost Lap"
  local scale  = 5
  local tw     = usagi.measure_text(title) * scale
  local _, th  = usagi.measure_text(title)
  local tx     = math.floor((usagi.GAME_W - tw) / 2)
  local ty     = math.floor(usagi.GAME_H / 3 - th * scale / 2)
  gfx.text_ex(title, tx, ty, scale, 0, gfx.COLOR_WHITE, 1)

  local w      = 200
  local race_x = math.floor((usagi.GAME_W - w) / 2)
  if ui.button("RACE", race_x, usagi.GAME_H - 80, { w = w, scale = 3 }) then
    SceneGoto("race")
  end
end

return M
