local car       = require "car"

local GAME_W    = 640
local GAME_H    = 352
local TILE_SIZE = 16
local COLS      = GAME_W / TILE_SIZE
local ROWS      = GAME_H / TILE_SIZE

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
  State = {
    map = build_map(),
    car = car.default_state(),
  }
  car.apply_upgrades(State.car, 0, 0, true, true, 5)
  car.reset(State.car, { col = COLS / 2, row = ROWS / 2 })
end

function _update(dt)
  if input.key_pressed(input.KEY_R) then
    car.reset(State.car, { col = COLS / 2, row = ROWS / 2 })
  end
  car.update(State.car, dt, State.map)
end

function _draw()
  gfx.clear(gfx.COLOR_INDIGO)
  car.draw_skid_marks(State.car)
  car.draw_flames(State.car)
  car.draw(State.car)
end
