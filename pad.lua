local car        = require "car"
local track_data = require "track_data"

-- A zip pad is a two-tile strip -- its anchor tile plus the tile across
-- `dir` -- that kicks the car forward when driven over. The boost is additive
-- along the car's current heading -- the drawn
-- arrow is cosmetic -- and goes through car.apply_boost, so it obeys the same
-- overspeed ceiling as the manual BTN3 boost. It fires once per pass: edge
-- triggered the frame the car's center enters the tile, re-armed once the
-- center leaves. Stateless like gates.lua apart from the per-pad `armed` flag;
-- the caller owns the pad list (car_dev keeps it on State.pads, reload-safe).
-- Tracks would declare pads in track_data and drive them from the race scene,
-- exactly like gates.

local M          = {}

local TILE_SIZE  = track_data.tile_size

-- Kick strength in px/s, added to vel and clamped by the overspeed cap inside
-- car.apply_boost. Punchier than the manual BTN3 boost (100) so routing over a
-- pad out-punches spamming the boost button. Tune freely.
M.IMPULSE        = 150

-- Arrow facing, used only by M.draw -- physics ignores it. Defaults east, the
-- spawn facing.
local DIR_ANGLE  = {
  east  = 0,
  south = math.pi / 2,
  west  = math.pi,
  north = -math.pi / 2,
}

-- Which way the strip's second tile sits relative to the anchor: one tile
-- across the arrow (perpendicular to `dir`), so the strip is a bar the car
-- drives into face-on -- a south pad is two tiles wide, an east pad two tall.
local DIR_STEP   = {
  east  = { 0, 1 },
  west  = { 0, 1 },
  north = { 1, 0 },
  south = { 1, 0 },
}

function M.new(col, row, dir)
  return { col = col, row = row, dir = dir or "east", armed = true }
end

-- The two tiles a pad occupies: its anchor plus the one across `dir`.
-- Everything spatial (the overlap test, the bounding rect, the draw) walks
-- this list, so the strip length lives in one place.
function M.tiles(pad)
  local step = DIR_STEP[pad.dir] or DIR_STEP.east
  return {
    { col = pad.col, row = pad.row },
    { col = pad.col + step[1], row = pad.row + step[2] },
  }
end

function M.rect(pad)
  local tiles = M.tiles(pad)
  local minc, maxc = tiles[1].col, tiles[1].col
  local minr, maxr = tiles[1].row, tiles[1].row
  for _, t in ipairs(tiles) do
    minc, maxc = math.min(minc, t.col), math.max(maxc, t.col)
    minr, maxr = math.min(minr, t.row), math.max(maxr, t.row)
  end
  return {
    x = minc * TILE_SIZE,
    y = minr * TILE_SIZE,
    w = (maxc - minc + 1) * TILE_SIZE,
    h = (maxr - minr + 1) * TILE_SIZE,
  }
end

-- Center-point test: the car "runs over" a pad only when its center tile is
-- one of the pad's tiles, so a corner clip at speed is a clean miss and
-- arm/re-arm is a single strip in/out (fires once per pass over the strip,
-- re-armed once the center leaves both tiles).
local function car_center_on(pad, c)
  local col = math.floor((c.x + car.SIZE / 2) / TILE_SIZE)
  local row = math.floor((c.y + car.SIZE / 2) / TILE_SIZE)
  for _, t in ipairs(M.tiles(pad)) do
    if col == t.col and row == t.row then return true end
  end
  return false
end

function M.apply(list, c)
  for _, pad in ipairs(list) do
    if car_center_on(pad, c) then
      if pad.armed then
        car.apply_boost(c, M.IMPULSE)
        pad.armed = false
      end
    else
      pad.armed = true
    end
  end
end

-- A pulsing double chevron on a translucent panel, pointing along pad.dir.
function M.draw(list)
  for _, pad in ipairs(list) do
    local ts       = TILE_SIZE
    local a        = DIR_ANGLE[pad.dir] or 0
    local pulse    = 0.55 + 0.45 * math.abs(math.sin(usagi.elapsed * 4))
    local fwd      = util.vec_from_angle(a, 1)
    local perp     = util.vec_from_angle(a + math.pi / 2, 1)
    -- Two stacked chevrons: the rear one dimmer, so the arrow reads as motion.
    local chevrons = {
      { push = 2,  color = gfx.COLOR_GREEN,      alpha = 0.5 * pulse },
      { push = -2, color = gfx.COLOR_TRUE_WHITE, alpha = pulse },
    }
    -- One panel + chevron pair per tile, so the strip reads as a runway.
    for _, t in ipairs(M.tiles(pad)) do
      local cx = t.col * ts + ts / 2
      local cy = t.row * ts + ts / 2
      gfx.rect_fill(t.col * ts, t.row * ts, ts, ts, gfx.COLOR_DARK_GREEN, 0.5)
      for _, ch in ipairs(chevrons) do
        local ox   = cx + fwd.x * ch.push
        local oy   = cy + fwd.y * ch.push
        local tipx = ox + fwd.x * 5
        local tipy = oy + fwd.y * 5
        gfx.tri_fill(
          tipx, tipy,
          ox - fwd.x * 3 - perp.x * 5, oy - fwd.y * 3 - perp.y * 5,
          ox - fwd.x * 3 + perp.x * 5, oy - fwd.y * 3 + perp.y * 5,
          ch.color, ch.alpha)
      end
    end
  end
end

return M
