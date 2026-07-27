local economy           = require "economy"
local track_data        = require "track_data"
local ui                = require "ui"
local reference         = require "reference"

local M                 = {}

-- Rank meter: a horizontal bar along the top of the screen split into five
-- equal zones (D on the left through S on the right), an arrow that rides the
-- live race rate, and each zone's rank letter overlaid on it. The S zone spans
-- the S threshold to 2x it; the arrow pegs past that.
local ZONES             = { "D", "C", "B", "A", "S" }
local BAR_W             = 304 -- length
local BAR_H             = 22  -- thickness
local LETTER_SCALE      = 3
-- Room above the bar for the arrow that rides its top edge.
local ARROW_ROOM        = 14
-- Max arrow speed in bar-fractions/sec for pace-driven target changes (a
-- collect bypasses this and snaps straight to target, below). Kept low on
-- purpose so the needle drifts toward pace changes rather than chasing the
-- projection's every wobble -- momentary arc-speed dips can't yank it far
-- before they reverse, so between collects it reads as a steady climb.
local SWEEP             = 1.5
-- Segments drawn per zone; also the shimmer stride for the S rainbow.
local ZONE_STEPS        = 8
local needle_pos        = 0 -- smoothed bar fraction, 0 (D floor) .. 1 (pegged)
local last_time         = nil
local last_phase        = nil
-- A collect flashes the arrow (arrow_flash), decaying back to 0, as a small
-- celebration on top of needle_pos -- the needle itself only ever shows the
-- honest value. A miss snaps needle_pos down directly without touching it.
local arrow_flash       = 0
local ARROW_FLASH_DECAY = 10   -- flash decay rate, 1/sec
-- Park the needle at the D floor until the car has covered this fraction of the
-- owned course, sidestepping the 0/0 projection singularity at the start; then
-- it sweeps up into the live projection.
local WARMUP            = 0.05

-- Low-time thresholds for the loop-countdown clock (see draw_clock).
local CLOCK_WARN_SECS   = 60   -- yellow at/under 1:00
local CLOCK_DANGER_SECS = 10   -- red + pulse at/under 0:10

-- The loop countdown formatted M:SS, ceil'd so the visible number only hits
-- 0:00 exactly at timeout (a live 0.4s still reads 0:01).
local function clock_text(secs)
  secs = math.max(0, math.ceil(secs))
  return string.format("%d:%02d", math.floor(secs / 60), secs % 60)
end

-- Unit ladder for the Nirvana ETA line, seconds up through millennia. Each
-- entry is { name, seconds-per-unit }; duration_text promotes to the next
-- unit at exactly 1.0 of it, always rendering one decimal.
local DURATION_UNITS = {
  { "sec",       1 },
  { "min",       60 },
  { "hours",     3600 },
  { "days",      86400 },
  { "weeks",     86400 * 7 },
  { "months",    86400 * 365 / 12 },
  { "years",     86400 * 365 },
  { "decades",   86400 * 365 * 10 },
  { "centuries", 86400 * 365 * 100 },
  { "millennia", 86400 * 365 * 1000 },
}

-- Formats a duration in seconds against DURATION_UNITS, picking the largest
-- unit that rounds to at least 1.0 (falling back to sec for anything under a
-- second). No cap on the top end -- centuries and millennia just keep growing.
-- Exported (M.duration_text) so the loop-2 TIME'S UP taunt can quote the same
-- ETA the HUD shows, instead of re-deriving its own unit ladder.
local function duration_text(secs)
  for i = #DURATION_UNITS, 2, -1 do
    local name, unit_secs = DURATION_UNITS[i][1], DURATION_UNITS[i][2]
    local value           = secs / unit_secs
    if math.floor(value * 10 + 0.5) / 10 >= 1.0 then
      return string.format("%.1f %s", value, name)
    end
  end
  return string.format("%.1f %s", secs, DURATION_UNITS[1][1])
end
M.duration_text = duration_text

-- Draws the loop clock with its left edge at (x, y) and the given scale. Color
-- escalates as the loop drains: white, yellow at/under a minute, red at/under
-- ten seconds; the red state also pulses (a sine on usagi.elapsed) so a
-- mid-lap timeout is never a surprise. One draw path; buy and race differ only
-- in the position/scale the caller passes.
local function draw_clock(x, y, scale)
  local secs  = State.loop_time_left or 0
  local text  = clock_text(secs)
  local color = gfx.COLOR_WHITE
  local alpha = 1
  if secs <= CLOCK_DANGER_SECS then
    color = gfx.COLOR_RED
    alpha = 0.55 + 0.45 * math.abs(math.sin(usagi.elapsed * 6))
  elseif secs <= CLOCK_WARN_SECS then
    color = gfx.COLOR_YELLOW
  end
  gfx.text_ex(text, x + 1, y + 1, scale, 0, gfx.COLOR_BLACK, alpha)
  gfx.text_ex(text, x, y, scale, 0, color, alpha)
end

-- Draws the cash readout -- the balance, with the passive ghost $/sec beneath
-- it once any ghost is running -- with its top edge at y. `place(w)` returns
-- the x for a line of width w, so the caller decides how the block is anchored:
-- buy centers it, race hangs it off the right edge.
local function draw_money(place, y, scale)
  local money_text  = string.format("$%.0f", State.money)
  local mw, mh      = usagi.measure_text(money_text)
  local money_x     = place(mw * scale)

  gfx.text_ex(money_text, money_x + 1, y + 1, scale, 0, gfx.COLOR_BLACK, 1)
  gfx.text_ex(money_text, money_x, y, scale, 0, gfx.COLOR_GREEN, 1)

  if economy.owns_any_ghost() then
    local rate      = economy.ghost_cash_rate()
    local rate_text = string.format("$%.2f/sec", rate)
    local rate_w    = usagi.measure_text(rate_text)
    local rate_y    = y + mh * scale + 3
    gfx.text_ex(rate_text, place(rate_w), rate_y, 1, 0, gfx.COLOR_LIGHT_GRAY, 1)

    local secs = economy.seconds_to_nirvana(rate)
    if secs then
      local eta_text = duration_text(secs) .. " to $300m"
      local eta_w    = usagi.measure_text(eta_text)
      local color    = secs < (State.loop_time_left or 0) and gfx.COLOR_GREEN or gfx.COLOR_LIGHT_GRAY
      gfx.text_ex(eta_text, place(eta_w), rate_y + mh + 3, 1, 0, color, 1)
    end
  end
end

-- Maps a $/sec rate onto the bar: each rank zone is a fifth of the height,
-- with the arrow interpolating between that rank's thresholds inside it.
local function bar_fraction(rate)
  local t      = track_data.ranks(State.active_track)
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

  local target
  if race.phase == "finished" then
    -- The real earned result. The live projection converges here as the
    -- remaining arc length goes to zero, so there's no end-of-race snap.
    target = bar_fraction(race.run_rate)
  else
    -- Projected finish rank from the car's current arc-speed. Parked at the
    -- D floor through the countdown and a short warmup (no elapsed time / no
    -- projection yet), then it sweeps up honestly.
    local rate = economy.projected_rate()
    if not rate or economy.race_progress() < WARMUP then
      target = 0
    else
      target = bar_fraction(rate)
    end
  end

  -- Reset to the D floor at the start of each race so the needle fills up from
  -- empty rather than inheriting the previous race's position.
  if race.phase ~= last_phase then
    if race.phase == "countdown" then
      needle_pos  = 0
      arrow_flash = 0
    end
    last_phase = race.phase
  end

  local dt = last_time and math.min(usagi.elapsed - last_time, 0.1) or 0
  last_time = usagi.elapsed

  -- A collect this frame snaps needle_pos straight to the new honest value
  -- instead of creeping there under the SWEEP cap, so it reads as a pop
  -- rather than a crawl. The finish teleports too: the earned rank is final,
  -- so it lands on the true value at once rather than easing in under the low
  -- SWEEP. Between collects the needle still eases toward pace-driven target
  -- changes at SWEEP speed.
  local jumped = #(race.events_this_frame or {}) > 0

  if jumped or race.phase == "finished" then
    needle_pos = target
  else
    local diff = target - needle_pos
    local step = SWEEP * dt
    if math.abs(diff) <= step then
      needle_pos = target
    else
      needle_pos = needle_pos + (diff > 0 and step or -step)
    end
  end

  arrow_flash = math.max(0, arrow_flash - ARROW_FLASH_DECAY * dt)

  -- On finish, snap straight to the earned rank and drop any lingering collect
  -- flash so the bar simply lands on the final value.
  if race.phase == "finished" then
    arrow_flash = 0
  end

  if jumped then
    arrow_flash = 1
  end

  local display_pos = math.min(1, needle_pos)

  -- One shadow rect under the whole bar, then the zone segments on top with
  -- their edges snapped to whole pixels: the half-transparent tiles must butt
  -- exactly, since an overlap double-blends dark and a gap exposes the shadow
  -- — either reads as a tick line.
  gfx.rect_fill(left + 1, top + 1, BAR_W, BAR_H, gfx.COLOR_BLACK, 0.5)
  -- Only the zone under the arrow shows its rank color; the rest gray out.
  local active_zone = math.min(math.floor(display_pos * 5) + 1, 5)
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

  -- Arrow riding the top edge of the bar, plus a line across it. A collect's
  -- arrow_flash decay rides underneath as a scale-pop + a yellow flash that
  -- fades to the plain white arrow; a miss (no flash) draws it plain, reading
  -- as a clean drop rather than a celebration.
  local nx  = bar_x(left, display_pos)
  local pop = 1 + arrow_flash * 0.9
  gfx.line_ex(nx + 1, top + 1, nx + 1, top + BAR_H + 1, 1, gfx.COLOR_BLACK, 0.5)
  gfx.line_ex(nx, top, nx, top + BAR_H, 1, gfx.COLOR_WHITE, 0.5)
  gfx.tri_fill(nx - 6 * pop, top - 11 * pop, nx + 8 * pop, top - 11 * pop, nx + 1, top + 1, gfx.COLOR_BLACK, 0.5)
  gfx.tri_fill(nx - 7 * pop, top - 12 * pop, nx + 7 * pop, top - 12 * pop, nx, top, gfx.COLOR_WHITE, 1)
  if arrow_flash > 0 then
    gfx.tri_fill(nx - 7 * pop, top - 12 * pop, nx + 7 * pop, top - 12 * pop, nx, top, gfx.COLOR_YELLOW, arrow_flash)
  end
end

function M.draw()
  -- With no reference line there's neither geometry nor timing to project from,
  -- so the bar hides entirely rather than falling back to the old meter.
  if State.mode == "race" and State.race and State.race.phase ~= "help" then
    if reference.has() then draw_bar() end
    -- Compact, top-left, tucked below the race scene's QUIT button so a mid-lap
    -- timeout is never a surprise. Same color states as the buy clock.
    draw_clock(5, 26, 2)
    -- Cash mirrors the clock across the screen: same row and scale, hung off
    -- the right margin so it grows leftward as the balance does instead of
    -- drifting into the clock. Live off State.money like the buy screen, so
    -- collects and ghost banks tick it up mid-race.
    draw_money(function(w) return usagi.GAME_W - 5 - w end, 26, 2)
    return
  end

  -- Loop countdown, prominent and top-center, above the money block (which is
  -- nudged down below it so the two don't collide).
  local clock_scale = 3
  local clock_str   = clock_text(State.loop_time_left or 0)
  local clock_w     = usagi.measure_text(clock_str) * clock_scale
  local _, clock_th = usagi.measure_text(clock_str)
  draw_clock(math.floor((usagi.GAME_W - clock_w) / 2), 4, clock_scale)

  draw_money(function(w) return (usagi.GAME_W - w) / 2 end, 4 + clock_th * clock_scale + 6, 3)
end

return M
