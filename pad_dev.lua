local car        = require "car"
local gates      = require "gates"
local pad        = require "pad"
local road       = require "road"
local track_data = require "track_data"

-- Pad prototyping playground on Track 2 (the track the player sees as
-- "Track 2" -- code id `basic`). Loads that track's real map, spawn, and
-- gates so zip-pad routing can be felt against the actual walls and racing
-- line, then lets you scatter pads live:
--
--   BTN1 / arrows  drive
--   R              reset car to spawn
--   P              drop a pad under the car, facing its heading
--   X              clear all pads
--
-- Pads live on State.pads and go through the same pad.apply / pad.draw the
-- race scene would use, so behaviour here matches a shipped track.

local TRACK_ID   = "basic"
local TILE_SIZE  = track_data.tile_size

local M          = {}

-- Nearest of the four cardinal dirs to a facing angle (east = 0, clockwise in
-- screen space since y grows downward). Only feeds the pad's cosmetic arrow --
-- the boost itself is along the car's heading regardless.
local DIRS       = { "east", "south", "west", "north" }
local function angle_to_dir(a)
  local q = math.floor((a % (2 * math.pi)) / (math.pi / 2) + 0.5) % 4
  return DIRS[q + 1]
end

local function car_tile(c)
  return math.floor((c.x + car.SIZE / 2) / TILE_SIZE),
      math.floor((c.y + car.SIZE / 2) / TILE_SIZE)
end

function _config()
  return {
    name        = "Pad Dev (Track 2)",
    game_width  = 640,
    game_height = 352,
  }
end

function _init()
  local tdata = track_data.TRACKS[TRACK_ID]
  State = {
    tdata = tdata,
    car   = car.default_state(),
    -- A couple of seed pads sitting on the track's authored coin line, a
    -- decent proxy for the racing line. Move/clear them with P and X.
    pads  = {
      pad.new(18, 7, "east"),
      pad.new(30, 14, "west"),
    },
  }
  -- Generous kit so the playground is fun to drive: full accel, drift +
  -- drift boost, max manual boost, reverse flip on.
  car.apply_upgrades(State.car, 4, 1, true, true, 5, true)
  car.reset(State.car, tdata.spawn)
end

function _update(dt)
  local tdata = State.tdata

  if input.key_pressed(input.KEY_R) then
    car.reset(State.car, tdata.spawn)
  end
  if input.key_pressed(input.KEY_F) then
    local col, row = car_tile(State.car)
    local dir      = angle_to_dir(car.pose(State.car).angle)
    table.insert(State.pads, pad.new(col, row, dir))
  end
  if input.key_pressed(input.KEY_D) then
    State.pads = {}
  end

  -- Same gate wall swap the race scene does, so pads interact with the real
  -- track geometry (including the movable gate walls).
  local gate_walls
  if tdata.gates and gates.enabled(State.car) then
    gate_walls = gates.apply_walls(tdata.gates, State.car, tdata.map)
  end
  car.update(State.car, dt, tdata.map)
  if gate_walls then
    gates.restore_walls(tdata.map, gate_walls)
  end

  pad.apply(State.pads, State.car)
end

function _draw()
  local tdata = State.tdata
  road.draw_track(tdata.map)

  -- Checkpoints drawn faded, purely as spatial context for routing.
  for i, cp in ipairs(tdata.checkpoints) do
    road.draw_checkpoint(cp, i, true, #tdata.checkpoints, false)
  end

  if tdata.gates and gates.enabled(State.car) then
    gates.draw(tdata.gates, State.car)
  end

  pad.draw(State.pads)
  car.draw_skid_marks(State.car)
  car.draw_headlights(State.car)
  car.draw_taillights(State.car)
  car.draw_boosts(State.car)
  car.draw_flames(State.car)
  car.draw(State.car)

  gfx.text_ex("R reset  P drop pad  X clear", 4, 2, 1, 0, gfx.COLOR_LIGHT_GRAY, 1)
end

return M
