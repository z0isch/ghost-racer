local economy    = require "economy"
local track_data = require "track_data"
local ui         = require "ui"

local M          = {}

-- Rank meter: a horizontal bar along the top of the screen split into five
-- equal zones (D on the left through S on the right), an arrow that rides the
-- live race rate, and each zone's rank letter overlaid on it. The S zone spans
-- the S threshold to 2x it; the arrow pegs past that.
local ZONES        = { "D", "C", "B", "A", "S" }
local BAR_W        = 304 -- length
local BAR_H        = 22  -- thickness
local LETTER_SCALE = 3
-- Room above the bar for the arrow that rides its top edge.
local ARROW_ROOM   = 14
-- Max arrow speed in bar-fractions/sec: quick enough to track any real
-- rate change, but never teleporting.
local SWEEP      = 3
-- Segments drawn per zone; also the shimmer stride for the S rainbow.
local ZONE_STEPS = 8
local needle_pos = 0 -- smoothed bar fraction, 0 (D floor) .. 1 (pegged)
local last_time  = nil
local last_phase = nil

-- Maps a $/sec rate onto the bar: each rank zone is a fifth of the height,
-- with the arrow interpolating between that rank's thresholds inside it.
local function bar_fraction(rate)
  local t      = track_data.ranks(State.active_track, State.loop)
  local bounds = { 0, t.C, t.B, t.A, t.S, t.S * 2 }
  if rate >= bounds[6] then return 1 end
  for i = 5, 1, -1 do
    if rate >= bounds[i] then
      return (i - 1) / 5 + ((rate - bounds[i]) / (bounds[i + 1] - bounds[i])) / 5
    end
  end
  return 0
end

-- Screen x at bar fraction `f` (0 = left end of the bar, 1 = right end).
local function bar_x(left, f)
  return left + f * BAR_W
end

local function draw_bar()
  local race  = State.race
  local left  = (usagi.GAME_W - BAR_W) / 2
  local top   = ARROW_ROOM
  -- Letters sit centered on the bar itself.
  local _, lh = usagi.measure_text("D")
  local ly    = top + (BAR_H - lh * LETTER_SCALE) / 2

  -- Highest rank actually reachable with the checkpoints currently owned.
  -- Unscaled this would be 1 (pegged past 2x S, where the live reading
  -- starts), but cp_fraction scales every measured rate down by the
  -- owned/total checkpoint ratio, so a partial track can't peg all the way
  -- to S the way a fully-bought one can.
  local t         = track_data.ranks(State.active_track, State.loop)
  local max_target = bar_fraction(t.S * 2 * economy.cp_fraction(State.active_track))

  local target
  if race.phase == "countdown" then
    target = max_target
  elseif race.phase == "finished" then
    -- The real earned result: never suppressed below its true value, even
    -- if it beats the assumed ceiling above.
    target = bar_fraction(race.run_rate)
  else
    -- The live reading is near-infinite for an instant at race start (time
    -- is near zero), which would otherwise re-peg past the countdown's
    -- capped position before decaying back down; clamp it to the same
    -- ceiling so the needle picks up smoothly where countdown left it.
    target = math.min(bar_fraction(economy.live_race_rate()), max_target)
  end

  -- Snap straight to the target on phase changes — the reachable ceiling
  -- for the countdown, and the live reading the moment the race starts (the
  -- rate starts pegged and decays until earnings land); the sweep below
  -- only smooths changes after that.
  if race.phase ~= last_phase then
    if race.phase == "countdown" or race.phase == "racing" then
      needle_pos = target
    end
    last_phase = race.phase
  end

  local dt   = last_time and math.min(usagi.elapsed - last_time, 0.1) or 0
  last_time  = usagi.elapsed
  local diff = target - needle_pos
  local step = SWEEP * dt
  if math.abs(diff) <= step then
    needle_pos = target
  else
    needle_pos = needle_pos + (diff > 0 and step or -step)
  end

  -- One shadow rect under the whole bar, then the zone segments on top with
  -- their edges snapped to whole pixels: the half-transparent tiles must butt
  -- exactly, since an overlap double-blends dark and a gap exposes the shadow
  -- — either reads as a tick line.
  gfx.rect_fill(left + 1, top + 1, BAR_W, BAR_H, gfx.COLOR_BLACK, 0.5)
  -- Only the zone under the arrow shows its rank color; the rest gray out.
  local active_zone = math.min(math.floor(needle_pos * 5) + 1, 5)
  for zi = 1, 5 do
    for s = 1, ZONE_STEPS do
      local f0 = (zi - 1) / 5 + (s - 1) / (5 * ZONE_STEPS)
      local f1 = (zi - 1) / 5 + s / (5 * ZONE_STEPS)
      local x0 = math.floor(bar_x(left, f0) + 0.5)
      local x1 = math.floor(bar_x(left, f1) + 0.5)
      local color = zi == active_zone and ui.rank_color(ZONES[zi], s)
          or gfx.COLOR_DARK_GRAY
      gfx.rect_fill(x0, top, x1 - x0, BAR_H, color, 0.5)
    end
  end

  -- End caps only; the zone boundaries read from the color changes.
  for i = 0, 5, 5 do
    local x = bar_x(left, i / 5)
    gfx.line_ex(x + 1, top - 1, x + 1, top + BAR_H + 3, 1, gfx.COLOR_BLACK, 0.5)
    gfx.line_ex(x, top - 2, x, top + BAR_H + 2, 1, gfx.COLOR_WHITE, 0.5)
  end

  -- Rank letters overlaid on the bar, one per zone at its mid-width. White
  -- over the zone colors (rank colors would vanish into their own zone), and
  -- plain text rather than ui.rank_text so they hold still. Letters outside
  -- the active zone dim along with it.
  for zi = 1, 5 do
    local letter = ZONES[zi]
    local lw     = usagi.measure_text(letter)
    local lx     = bar_x(left, (zi - 0.5) / 5) - lw * LETTER_SCALE / 2
    local color  = zi == active_zone and gfx.COLOR_WHITE or gfx.COLOR_LIGHT_GRAY
    local alpha  = zi == active_zone and 1 or 0.5
    gfx.text_ex(letter, lx + 1, ly + 1, LETTER_SCALE, 0, gfx.COLOR_BLACK, alpha)
    gfx.text_ex(letter, lx, ly, LETTER_SCALE, 0, color, alpha)
  end

  -- Arrow riding the top edge of the bar, plus a line across it.
  local nx = bar_x(left, needle_pos)
  gfx.line_ex(nx + 1, top + 1, nx + 1, top + BAR_H + 1, 1, gfx.COLOR_BLACK, 0.5)
  gfx.line_ex(nx, top, nx, top + BAR_H, 1, gfx.COLOR_WHITE, 0.5)
  gfx.tri_fill(nx - 6, top - 11, nx + 8, top - 11, nx + 1, top + 1, gfx.COLOR_BLACK, 0.5)
  gfx.tri_fill(nx - 7, top - 12, nx + 7, top - 12, nx, top, gfx.COLOR_WHITE, 1)
end

function M.draw()
  -- The race HUD is just the rank meter; the cash readouts stay out of it.
  if State.mode == "race" and State.race and State.race.phase ~= "help" then
    draw_bar()
    return
  end

  local scale        = 3
  local _, th        = usagi.measure_text("0")
  local bal_y        = 6
  local total_rate_y = bal_y + th * scale + 3
  local rate_y       = total_rate_y

  local money_text   = string.format("$%.0f", State.money)
  local cash_w       = usagi.measure_text(money_text) * scale
  local cash_x       = (usagi.GAME_W - cash_w) / 2

  gfx.text_ex(money_text, cash_x + 1, bal_y + 1, scale, 0, gfx.COLOR_BLACK, 1)
  gfx.text_ex(money_text, cash_x, bal_y, scale, 0, gfx.COLOR_GREEN, 1)

  if economy.owns_any_ghost() then
    local total_rate_text = string.format("$%.2f/sec", economy.ghost_cash_rate())
    local total_rate_w    = usagi.measure_text(total_rate_text)
    local total_rate_x    = (usagi.GAME_W - total_rate_w) / 2
    gfx.text_ex(total_rate_text, total_rate_x, total_rate_y, 1, 0, gfx.COLOR_LIGHT_GRAY, 1)
    rate_y = rate_y + th + 4
  end
end

return M
