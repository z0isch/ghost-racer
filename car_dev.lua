local car            = require "car"

local GAME_W         = 640
local GAME_H         = 352
local TILE_SIZE      = 16
local COLS           = GAME_W / TILE_SIZE
local ROWS           = GAME_H / TILE_SIZE

-- --- gates (prototype; extract to gates.lua if it's fun) --------------------
-- A gate is a 1-tile-wide strip that is solid wall unless the car is driving
-- in its required gear: green ("forward") gates open only for a car moving
-- forward, red ("reverse") only for one reversing. Rather than teaching
-- car.lua about gates, blocking
-- gates are stamped into the map as wall tiles around car.update and restored
-- after, so the existing wall collision/decel applies unchanged. A car
-- overlapping a gate is exempt from blocking, so if you stop on one you can
-- drive out in either direction.

local gates          = {}

local GATE_WALL_TILE = 2

function gates.new(col, row, len, vertical, mode)
  return { col = col, row = row, len = len, vertical = vertical, mode = mode }
end

function gates.rect(gate)
  local w = gate.vertical and 1 or gate.len
  local h = gate.vertical and gate.len or 1
  return { x = gate.col * TILE_SIZE, y = gate.row * TILE_SIZE, w = w * TILE_SIZE, h = h * TILE_SIZE }
end

-- True when the car's collision footprint occupies any gate tile, using the
-- exact sample points road.on_road floors into tiles. A pixel-rect overlap
-- test is NOT equivalent: pressed flush against a walled gate, a fractional
-- car position can overlap the gate rect by under a pixel while every sampled
-- tile is still outside it, which would wrongly lift the wall.
local function on_gate_tiles(gate, c)
  local ts       = TILE_SIZE
  local m        = car.MARGIN
  local inner    = car.SIZE - m - 1
  local col1     = math.floor((c.x + m) / ts)
  local col2     = math.floor((c.x + inner) / ts)
  local row1     = math.floor((c.y + m) / ts)
  local row2     = math.floor((c.y + inner) / ts)
  local gate_col = gate.col + (gate.vertical and 0 or gate.len - 1)
  local gate_row = gate.row + (gate.vertical and gate.len - 1 or 0)
  return col1 <= gate_col and col2 >= gate.col
      and row1 <= gate_row and row2 >= gate.row
end

function gates.blocks(gate, c)
  local correct = (gate.mode == "forward" and c.vel > 0)
      or (gate.mode == "reverse" and c.vel < 0)
  if correct then return false end
  return not on_gate_tiles(gate, c)
end

function gates.apply_walls(list, c, map)
  local data  = map.layers[1].data
  local saved = {}
  for _, gate in ipairs(list) do
    if gates.blocks(gate, c) then
      for i = 0, gate.len - 1 do
        local col = gate.col + (gate.vertical and 0 or i)
        local row = gate.row + (gate.vertical and i or 0)
        local idx = row * map.width + col + 1
        saved[#saved + 1] = { idx = idx, tile = data[idx] }
        data[idx] = GATE_WALL_TILE
      end
    end
  end
  return saved
end

function gates.restore_walls(map, saved)
  local data = map.layers[1].data
  for _, s in ipairs(saved) do
    data[s.idx] = s.tile
  end
end

function gates.draw(list, c)
  for _, gate in ipairs(list) do
    local r     = gates.rect(gate)
    local color = gate.mode == "forward" and gfx.COLOR_GREEN or gfx.COLOR_RED
    local alpha = gates.blocks(gate, c) and 0.9 or 0.45
    gfx.rect_fill(r.x, r.y, r.w, r.h, color, alpha)
    gfx.rect(r.x, r.y, r.w, r.h, color)
  end
end

-- -----------------------------------------------------------------------------

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
    map   = build_map(),
    car   = car.default_state(),
    gates = {
      gates.new(12, 8, 12, true, "forward"),
      gates.new(28, 8, 12, true, "reverse"),
    },
  }
  car.apply_upgrades(State.car, 0, 0, true, true, 5, true)
  car.reset(State.car, { col = COLS / 2, row = ROWS / 2 })
end

function _update(dt)
  if input.key_pressed(input.KEY_R) then
    car.reset(State.car, { col = COLS / 2, row = ROWS / 2 })
  end
  local saved = gates.apply_walls(State.gates, State.car, State.map)
  car.update(State.car, dt, State.map)
  gates.restore_walls(State.map, saved)
end

function _draw()
  gfx.clear(gfx.COLOR_INDIGO)
  gates.draw(State.gates, State.car)
  car.draw_skid_marks(State.car)
  car.draw_headlights(State.car)
  car.draw_taillights(State.car)
  car.draw_flames(State.car)
  car.draw(State.car)
end
