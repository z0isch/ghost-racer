local car        = require "car"
local track_data = require "track_data"

-- A gate is a 1-tile-wide strip that is solid wall unless the car is driving
-- in its required pose: green ("forward") gates open only for a car
-- traveling hood-first, red ("reverse") only for one traveling trunk-first.
-- Pose comes from actual travel vs facing, not gear sign, so a car that has
-- spun 180 mid-drift or mid-flip and is still sliding its original line
-- already counts as reversing. Rather than teaching car.lua about gates,
-- blocking gates are stamped into the map as wall tiles around car.update
-- and restored after, so the existing wall collision/decel applies unchanged.
-- A car overlapping a gate is exempt from blocking, so if you stop on one
-- you can drive out in either direction.
--
-- Tracks declare gates in track_data (authored un-mirrored, like
-- checkpoints/coins) and the race scene applies them only while gates are
-- enabled - see M.enabled.

local M              = {}

local TILE_SIZE      = track_data.tile_size

local GATE_WALL_TILE = 2

-- Gates only exist for a car that can reverse; without the flip/reverse
-- moves a "forward"-only wall is just a wall. Same fallback formula as
-- car.apply_upgrades, so this reads correctly even before upgrades have
-- been applied to a fresh save's car.
function M.enabled(c)
  return c.reverse_enabled or track_data.REVERSE_MODE
end

function M.new(col, row, len, vertical, mode)
  return { col = col, row = row, len = len, vertical = vertical, mode = mode }
end

function M.rect(gate)
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

function M.blocks(gate, c)
  -- Judged along the gate's crossing axis (x for vertical strips, y for
  -- horizontal): hood-first when nose and actual travel point the same way
  -- through the gate, trunk-first when opposite. Sideways slide doesn't
  -- count, so a mid-drift or mid-flip 180 reads as reversing as soon as the
  -- nose swings past the gate plane, even though vel is still positive.
  local travel  = c.vel * (gate.vertical and math.cos(c.vel_angle) or math.sin(c.vel_angle))
  local nose    = gate.vertical and math.cos(c.facing_angle) or math.sin(c.facing_angle)
  local through = travel * nose
  local correct = (gate.mode == "forward" and through > 0)
      or (gate.mode == "reverse" and through < 0)
  if correct then return false end
  return not on_gate_tiles(gate, c)
end

function M.apply_walls(list, c, map)
  local data  = map.layers[1].data
  local saved = {}
  for _, gate in ipairs(list) do
    if M.blocks(gate, c) then
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

function M.restore_walls(map, saved)
  local data = map.layers[1].data
  for _, s in ipairs(saved) do
    data[s.idx] = s.tile
  end
end

-- Pass nil for the car (as the buy scene's track backdrop does) to draw
-- every gate at the low "open" alpha with no blocked-state claim.
function M.draw(list, c)
  for _, gate in ipairs(list) do
    local r     = M.rect(gate)
    local color = gate.mode == "forward" and gfx.COLOR_DARK_BLUE or gfx.COLOR_DARK_PURPLE
    local alpha = (c and M.blocks(gate, c)) and 0.9 or 0.2
    gfx.rect_fill(r.x, r.y, r.w, r.h, color, alpha)
  end
end

return M
