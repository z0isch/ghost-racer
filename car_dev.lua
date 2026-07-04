local car       = require "car"

local GAME_W    = 640
local GAME_H    = 352
local TILE_SIZE = 16
local COLS      = GAME_W / TILE_SIZE
local ROWS      = GAME_H / TILE_SIZE

local map

local function build_map()
  local data = {}
  for i = 1, COLS * ROWS do
    data[i] = 1
  end
  return { width = COLS, height = ROWS, layers = { { data = data } } }
end

function _config()
  return {
    name        = "Car Dev",
    game_width  = GAME_W,
    game_height = GAME_H,
  }
end

function _init()
  map = build_map()
  car.reset({ col = COLS / 2, row = ROWS / 2 })
end

function _update(dt)
  if input.key_pressed(input.KEY_R) then
    car.reset({ col = COLS / 2, row = ROWS / 2 })
  end
  car.update(dt, map)
end

function _draw()
  gfx.clear(gfx.COLOR_INDIGO)
  car.draw_skid_marks()
  car.draw_flames()
  car.draw()
end
