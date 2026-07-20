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
-- Transient juice layered on top of needle_pos, separate from the honest
-- value: jump_offset spikes on a collect and decays back to 0 for the
-- overshoot pop; arrow_flash drives the arrow's matching flash + scale-pop.
-- A miss snaps needle_pos down directly without touching either.
local jump_offset       = 0
local arrow_flash       = 0
local JUMP_POP          = 0.05 -- overshoot spike, in bar fractions
-- A cheap coin/checkpoint moves the honest needle only a hair, so on its own
-- the pop would barely read. Below this delta, extra overshoot is blended in
-- (up to JUMP_POP_BOOST at delta 0) so even the smallest collect still pops.
local SMALL_JUMP_REF    = 0.01
local JUMP_POP_BOOST    = 0.01
local JUMP_DECAY        = 0.01 -- overshoot decay rate, bar-fractions/sec (~0.25s taper off the peak pop)
local ARROW_FLASH_DECAY = 10   -- flash decay rate, 1/sec
-- Park the needle at the D floor until the car has covered this fraction of the
-- owned course, sidestepping the 0/0 projection singularity at the start; then
-- it sweeps up into the live projection.
local WARMUP            = 0.05

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
      jump_offset = 0
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
  local pre_jump_pos = needle_pos

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

  -- Decay first, then apply this frame's spike on top -- otherwise a fresh
  -- spike gets knocked down by the same-frame decay step before it's ever
  -- drawn (JUMP_DECAY * dt alone can exceed JUMP_POP), so the overshoot never
  -- actually rendered.
  jump_offset = math.max(0, jump_offset - JUMP_DECAY * dt)
  arrow_flash = math.max(0, arrow_flash - ARROW_FLASH_DECAY * dt)

  -- On finish, snap straight to the earned rank: kill any transient pop still
  -- decaying from a coin grabbed right before the line, so the bar lands on the
  -- final value at once instead of overshooting and easing down onto it.
  if race.phase == "finished" then
    jump_offset = 0
    arrow_flash = 0
  end

  if jumped then
    local delta = math.abs(target - pre_jump_pos)
    local boost = math.max(0, SMALL_JUMP_REF - delta) / SMALL_JUMP_REF
    jump_offset = JUMP_POP + JUMP_POP_BOOST * boost
    arrow_flash = 1
  end

  -- needle_pos stays the honest baseline the meter's zone/letter state reads;
  -- jump_offset is only composited into what's drawn below, so the overshoot
  -- pop never corrupts the tracked value.
  local display_pos = math.min(1, needle_pos + jump_offset)

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
  -- jump_offset/arrow_flash decay rides underneath as a scale-pop + a yellow
  -- flash that fades to the plain white arrow; a miss (no jump_offset) draws
  -- it plain, reading as a clean drop rather than a celebration.
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
  -- The race HUD is just the rank meter; the cash readouts stay out of it.
  -- With no reference line there's neither geometry nor timing to project from,
  -- so the bar hides entirely rather than falling back to the old meter.
  if State.mode == "race" and State.race and State.race.phase ~= "help" then
    if reference.has() then draw_bar() end
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
