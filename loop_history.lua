-- Per-loop record of the ghost $/sec the player ended on, plus the graph drawn
-- from it. One entry per loop, appended when that loop's clock runs out (see
-- scenes/buy's timeout sequence).
--
-- The stored figure is the rate, but the graph plots what the rate *means*:
-- how long $300m would take at it (NIRVANA_COST / rate, the same estimate the
-- HUD's "to $300m" readout makes). That's the number the loop is actually
-- about - the player isn't chasing income, they're chasing a wait short enough
-- to fit inside a five-minute clock - and it turns an abstract "$41k/sec" into
-- "2.1 hours", which can be compared against the clock without doing any math.
--
-- The axis is inverted: shorter waits sit higher, so the climb still reads as a
-- line going up, and the goal (LOOP_SECONDS - $300m inside one loop) is the top
-- of the plot rather than the bottom. It's log-scaled, because the wait
-- collapses multiplicatively - loop 2 might be centuries and loop 12 minutes -
-- and on a linear axis every early loop pins to the same edge and the
-- progression the graph exists to show disappears. `opts.scale = "linear"` is
-- there for comparison in the dev harness (loop_history_dev.lua); the game uses
-- the default.
--
-- Loop 1 always ends at $0/sec (ghosts don't exist until loop 2), which is not
-- a long wait but no wait at all - $300m never arrives. Those entries get their
-- own flat row under the axis labelled "never", instead of being pinned to the
-- bottom of the band where they'd read as merely slow.

local track_data    = require "track_data"

local M             = {}

-- Points needed before the graph says anything; below this the loop-end modal
-- skips the step entirely (one dot is not a progression).
M.MIN_POINTS        = 2

-- Default size of the plot as it appears in the loop-end modal, sized to sit
-- inside the panel without pushing it past the 640px screen.
M.GRAPH_W           = 400
M.GRAPH_H           = 132

local PAD           = 4   -- gap between the label gutter and the plot
local NEVER_BAND_H  = 11  -- height of the separate row "never" entries sit in
-- Smallest log-space height of the value axis, in decades. Without a floor, a
-- run of near-identical waits would stretch its noise across the full plot and
-- read as dramatic progress; holding at least this much range keeps a flat run
-- looking flat.
local MIN_SPAN_DECS = 0.6
local SPAN_PAD      = 0.06  -- fraction of the value range left clear top/bottom
local MAX_X_LABELS  = 6
local MIN_TICK_GAP  = 9     -- px; y ticks closer than this are dropped
-- Axis titles. Both sit in space the plot already reserves - the x title on the
-- number row, in the gutter beside it; the y title inside the top of the plot -
-- so naming the axes costs the graph no height. Without them the numbers are
-- bare: "1 2 3" could be anything, and "3.0mo" doesn't say a wait for what.
local X_AXIS_TITLE  = "Loop"
local Y_AXIS_TITLE  = "to $300m"

local COL_BG        = gfx.COLOR_BLACK
local COL_FRAME     = gfx.COLOR_DARK_GRAY
local COL_GRID      = gfx.COLOR_DARK_GRAY
local COL_LABEL     = gfx.COLOR_LIGHT_GRAY
local COL_LINE      = gfx.COLOR_GREEN
local COL_POINT     = gfx.COLOR_GREEN
local COL_NEVER     = gfx.COLOR_RED
local COL_LATEST    = gfx.COLOR_YELLOW
local COL_GOAL      = gfx.COLOR_BLUE

local NEVER         = math.huge

-- ---------------------------------------------------------------- recording

-- A fresh, empty history. Its own constructor so persist's default_state
-- doesn't have to know the shape.
function M.new()
  return {}
end

-- Records `rate` as the ending $/sec of `loop`. Upsert, not append: the
-- loop-end modal can be re-raised for the same loop (quit and reload with a
-- dead clock re-runs the timeout sequence - see scenes/buy.update), and that
-- must correct the entry rather than stack a duplicate on top of it.
function M.record(hist, loop, rate)
  rate = math.max(0, tonumber(rate) or 0)
  local last = hist[#hist]
  if last and last.loop == loop then
    last.rate = rate
    return false
  end
  hist[#hist + 1] = { loop = loop, rate = rate }
  return true
end

-- Sanitizes a loaded history: drops malformed entries, coerces the numbers,
-- and sorts by loop. Loops run five minutes, so the list stays short enough
-- that there's no cap - and capping would cost the early entries, which are
-- the whole point of the comparison.
function M.sanitize(loaded)
  local hist = {}
  if type(loaded) ~= "table" then return hist end
  for _, e in ipairs(loaded) do
    local loop, rate = tonumber(e and e.loop), tonumber(e and e.rate)
    if loop and rate then
      hist[#hist + 1] = { loop = math.floor(loop), rate = math.max(0, rate) }
    end
  end
  table.sort(hist, function(a, b) return a.loop < b.loop end)
  return hist
end

-- True once there's enough history for the graph to be worth showing.
function M.has_graph(hist)
  return hist ~= nil and #hist >= M.MIN_POINTS
end

-- ------------------------------------------------------------- formatting

-- Seconds for `rate` to earn Nirvana from nothing - the plotted value. NEVER
-- (infinite) at no income, which is loop 1 and any loop that ends with no
-- ghost running. Unlike economy.seconds_to_nirvana this ignores money on hand:
-- the entries have to be comparable across loops, and each loop starts broke.
function M.eta_of(rate)
  if not rate or rate <= 0 then return NEVER end
  return track_data.NIRVANA_COST / rate
end

-- Unit ladder for the Nirvana ETA, seconds up through millennia. Each entry is
-- { long name, short suffix, seconds-per-unit }; the formatters promote to the
-- next unit at exactly 1.0 of it.
local DURATION_UNITS = {
  { "sec",       "s",  1 },
  { "min",       "m",  60 },
  { "hours",     "h",  3600 },
  { "days",      "d",  86400 },
  { "weeks",     "w",  86400 * 7 },
  { "months",    "mo", 86400 * 365 / 12 },
  { "years",     "y",  86400 * 365 },
  { "decades",   "de", 86400 * 365 * 10 },
  { "centuries", "c",  86400 * 365 * 100 },
  { "millennia", "ky", 86400 * 365 * 1000 },
}

local function unit_for(secs)
  for i = #DURATION_UNITS, 2, -1 do
    local u = DURATION_UNITS[i]
    if math.floor(secs / u[3] * 10 + 0.5) / 10 >= 1.0 then return u end
  end
  return DURATION_UNITS[1]
end

-- Formats a duration in seconds against DURATION_UNITS, picking the largest
-- unit that rounds to at least 1.0 (falling back to sec for anything under a
-- second). No cap on the top end - centuries and millennia just keep growing.
-- Shared with the HUD's "to $300m" readout and the loop-2 TIME'S UP taunt, so
-- the graph and the line the player has been staring at all loop agree.
function M.duration_text(secs)
  if secs == NEVER then return "never" end
  local u = unit_for(secs)
  return string.format("%.1f %s", secs / u[3], u[1])
end

-- Same duration, squeezed for the axis gutter: no space, short suffix, and no
-- decimal once the number is two digits wide ("2.4d", "18y"). Stops promoting
-- at years and switches to k/m prefixes past a thousand of them - "23y" and
-- "1.2my" read at a glance where "2.3de" and "1.2 millennia" don't.
local YEAR = 86400 * 365
function M.short_duration(secs)
  if secs == NEVER then return "never" end
  local function fmt(v, suffix)
    if v >= 9.95 then return string.format("%.0f%s", v, suffix) end
    return string.format("%.1f%s", v, suffix)
  end
  if secs >= YEAR * 1e6 then return fmt(secs / (YEAR * 1e6), "my") end
  if secs >= YEAR * 1e3 then return fmt(secs / (YEAR * 1e3), "ky") end
  if secs >= YEAR then return fmt(secs / YEAR, "y") end
  local u = unit_for(secs)
  return fmt(secs / u[3], u[2])
end

-- Compact magnitude for a $/sec figure. Kept for the dev harness's readout of
-- the underlying rates; the graph itself talks in durations.
function M.short_money(v)
  local a = math.abs(v)
  if a >= 1e9 then return string.format("$%.1fb", v / 1e9) end
  if a >= 1e6 then return string.format("$%.1fm", v / 1e6) end
  if a >= 1e3 then return string.format("$%.1fk", v / 1e3) end
  if a >= 10 then return string.format("$%.0f", v) end
  return string.format("$%.2f", v)
end

function M.rate_text(v)
  return M.short_money(v) .. "/sec"
end

-- Progress from `prev` to `cur` as a factor on the wait ("4.1x faster"), or nil
-- when there's no meaningful ratio to state: no previous loop, or either end
-- infinite (the first ghost cuts an infinite wait by an infinite factor).
function M.speedup_text(prev, cur)
  if not prev or prev == NEVER or not cur or cur == NEVER or cur <= 0 then return nil end
  if cur <= prev then return string.format("%.1fx faster", prev / cur) end
  return string.format("%.1fx slower", cur / prev)
end

-- ------------------------------------------------------------------- axis

-- Durations worth a gridline, ascending. Powers of ten in seconds would put
-- lines at 1.2 days and 3.2 years; these are the round intervals a player
-- already thinks in, so a label can be read without converting it.
local NICE_TICKS = {
  1, 5, 15, 30,
  60, 120, 180, 300, 600, 900, 1800,
  3600, 3 * 3600, 6 * 3600, 12 * 3600,
  86400, 3 * 86400, 7 * 86400, 14 * 86400,
  30 * 86400, 90 * 86400, 182 * 86400,
}
do
  -- 1y, 3y, 10y, 30y ... up to a million years; past that the axis just clamps
  -- its own ends, which no real history reaches anyway.
  local mag = 1
  while mag <= 1e6 do
    NICE_TICKS[#NICE_TICKS + 1] = YEAR * mag
    NICE_TICKS[#NICE_TICKS + 1] = YEAR * mag * 3
    mag = mag * 10
  end
end

-- Value axis for a set of ETAs. Returns a table with:
--   frac(v)   -> 0..1 height of v in the finite band, 1 = top = shortest wait
--                (nil for NEVER, which has its own row)
--   ticks     -> { { v = seconds, f = frac }, ... } gridlines, bottom-up
--   has_never -> whether any entry sits in the "never" row
local function build_axis(etas, linear)
  local lo, hi, has_never
  for _, v in ipairs(etas) do
    if v ~= NEVER then
      lo = (not lo or v < lo) and v or lo
      hi = (not hi or v > hi) and v or hi
    else
      has_never = true
    end
  end

  -- Nothing finite to plot (a history of loop 1s): every entry is a "never",
  -- so the band is unused and frac never gets called.
  if not lo then
    return { frac = function() return nil end, ticks = {}, has_never = true }
  end

  if linear then
    -- Linear runs from 0 at the top, so the plot is honest about how much of
    -- the wait is actually left. Kept for the dev harness's side-by-side; see
    -- the module note.
    local bot = hi * (1 + SPAN_PAD)
    if bot <= 0 then bot = 1 end
    local ticks = {}
    for i = 0, 2 do
      local v = bot * i / 2
      ticks[#ticks + 1] = { v = v, f = 1 - v / bot }
    end
    return {
      frac = function(v) return v ~= NEVER and math.max(0, 1 - v / bot) or nil end,
      ticks = ticks,
      has_never = has_never,
    }
  end

  local lo_l, hi_l = math.log(lo, 10), math.log(hi, 10)
  -- Expand a too-narrow range about its center, so a stalled run reads flat
  -- instead of having its noise magnified to fill the plot.
  local span       = hi_l - lo_l
  if span < MIN_SPAN_DECS then
    local mid = (lo_l + hi_l) / 2
    lo_l, hi_l = mid - MIN_SPAN_DECS / 2, mid + MIN_SPAN_DECS / 2
    span = MIN_SPAN_DECS
  end
  local pad = span * SPAN_PAD
  lo_l, hi_l = lo_l - pad, hi_l + pad
  span = hi_l - lo_l

  -- Inverted: the shortest wait (lo_l) is the top of the band.
  local function frac(v)
    if v == NEVER then return nil end
    return math.min(1, math.max(0, (hi_l - math.log(v, 10)) / span))
  end

  -- Gridlines at the round durations inside the range, top-down in value so
  -- the list comes out bottom-up in screen position (what the thinning pass
  -- below wants). A range too tight to contain two of them labels its own ends.
  local ticks = {}
  for i = #NICE_TICKS, 1, -1 do
    local v = NICE_TICKS[i]
    if v >= 10 ^ lo_l and v <= 10 ^ hi_l then
      ticks[#ticks + 1] = { v = v, f = frac(v) }
    end
  end
  if #ticks < 2 then
    ticks = { { v = 10 ^ hi_l, f = 0 }, { v = 10 ^ lo_l, f = 1 } }
  end

  return { frac = frac, ticks = ticks, has_never = has_never }
end

-- Indices to label on the loop axis: always the first and last, with evenly
-- spaced ones between until MAX_X_LABELS is used up. A long run would collide
-- its labels into a smear otherwise.
local function x_label_indices(n)
  local want = {}
  if n <= MAX_X_LABELS then
    for i = 1, n do want[i] = true end
    return want
  end
  want[1], want[n] = true, true
  local slots = MAX_X_LABELS - 2
  for k = 1, slots do
    want[math.floor(1 + (n - 1) * k / (slots + 1) + 0.5)] = true
  end
  return want
end

-- ------------------------------------------------------------------- draw

-- Draws the progression graph in the box at (x, y, w, h). Caller guarantees
-- M.has_graph(hist).
-- opts: scale ("log" default, or "linear"), frame (bool, default true).
function M.draw(hist, x, y, w, h, opts)
  opts            = opts or {}
  local linear    = opts.scale == "linear"
  local _, line_h = usagi.measure_text("0")

  local etas      = {}
  for i, e in ipairs(hist) do etas[i] = M.eta_of(e.rate) end
  local axis   = build_axis(etas, linear)

  -- Gutter is measured from the labels that will actually be drawn, so a
  -- series in the millennia doesn't overrun a gutter sized for two digits.
  local gutter = 0
  for _, t in ipairs(axis.ticks) do
    gutter = math.max(gutter, usagi.measure_text(M.short_duration(t.v)))
  end
  if axis.has_never then
    gutter = math.max(gutter, usagi.measure_text("never"))
  end
  -- The x title shares the gutter with the tick labels, so it has to fit there
  -- too or it would hang off the left edge of the box.
  gutter        = math.max(gutter, usagi.measure_text(X_AXIS_TITLE))

  local plot_l  = x + gutter + PAD
  local plot_r  = x + w - 2
  local plot_w  = plot_r - plot_l
  -- Half a line of headroom top and bottom: tick labels are centered on their
  -- gridline, and the topmost/bottommost would otherwise clip out of the box.
  local top     = y + math.floor(line_h / 2) + 1
  local axis_y  = y + h - line_h - 2    -- the loop-number row sits below this
  local never_y = axis_y - math.floor(NEVER_BAND_H / 2)
  local band_b  = axis.has_never and (axis_y - NEVER_BAND_H) or axis_y
  local band_h  = band_b - top

  if opts.frame ~= false then
    gfx.rect_fill(x, y, w, h, COL_BG)
    gfx.rect(x, y, w, h, COL_FRAME)
  end

  local n = #hist
  local function px(i)
    if n == 1 then return plot_l + plot_w / 2 end
    return plot_l + plot_w * (i - 1) / (n - 1)
  end
  -- Finite waits live in the band; "never" sits in its own row beneath it.
  local function py(v)
    local f = axis.frac(v)
    if not f then return never_y end
    return band_b - f * band_h
  end

  -- Value gridlines, skipping any that would land on top of the one below it.
  local last_ty
  for _, t in ipairs(axis.ticks) do
    local ty = band_b - t.f * band_h
    if not last_ty or math.abs(ty - last_ty) >= MIN_TICK_GAP then
      last_ty     = ty
      local label = M.short_duration(t.v)
      gfx.line(plot_l, ty, plot_r, ty, COL_GRID, 0.5)
      gfx.text(label, plot_l - PAD - usagi.measure_text(label),
        ty - math.floor(line_h / 2), COL_LABEL, 0.8)
    end
  end

  -- The finish line: a wait that fits inside one loop's clock is a wait the
  -- player can actually sit through, so that's the height the whole graph is
  -- climbing toward. Only drawn once the series is close enough for it to fall
  -- inside the band - off-scale it would just be the top edge, saying nothing.
  local goal_f = axis.frac(track_data.LOOP_SECONDS)
  if goal_f and goal_f > 0.02 and goal_f < 0.98 then
    local gy = band_b - goal_f * band_h
    gfx.line(plot_l, gy, plot_r, gy, COL_GOAL, 0.9)
  end

  -- The "never" row, fenced off from the log band by its own rule so a loop
  -- with no ghost income can't be misread as a very long wait.
  if axis.has_never then
    gfx.line(plot_l, band_b, plot_r, band_b, COL_FRAME, 0.9)
    gfx.text("never", plot_l - PAD - usagi.measure_text("never"),
      never_y - math.floor(line_h / 2), COL_NEVER, 0.8)
  end

  gfx.line(plot_l, top, plot_l, axis_y, COL_FRAME)
  gfx.line(plot_l, axis_y, plot_r, axis_y, COL_FRAME)

  -- Y title, tucked into the top-left of the plot: the tick labels below it are
  -- durations, and this is what they're a duration of. Shadowed, since the
  -- series can pass under it on a run that starts strong. Dropped rather than
  -- overlapped when the plot is too narrow to hold it (the dev harness's
  -- shrunk copy).
  if usagi.measure_text(Y_AXIS_TITLE) < plot_w - 4 then
    gfx.text(Y_AXIS_TITLE, plot_l + 3, y + 2, COL_BG, 0.9)
    gfx.text(Y_AXIS_TITLE, plot_l + 2, y + 1, COL_LABEL, 0.8)
  end

  -- Series: a black offset copy first, so the line stays readable where it
  -- crosses a gridline.
  for i = 1, n - 1 do
    local x1, y1 = px(i), py(etas[i])
    local x2, y2 = px(i + 1), py(etas[i + 1])
    gfx.line(x1, y1 + 1, x2, y2 + 1, COL_BG)
    gfx.line(x1, y1, x2, y2, COL_LINE)
  end

  -- X title, right-aligned in the gutter on the number row, so it reads as the
  -- heading of the numbers to its right.
  gfx.text(X_AXIS_TITLE, plot_l - PAD - usagi.measure_text(X_AXIS_TITLE),
    axis_y + 2, COL_LABEL, 0.8)

  local labels = x_label_indices(n)
  for i, e in ipairs(hist) do
    local cx, cy = px(i), py(etas[i])
    local color  = etas[i] ~= NEVER and COL_POINT or COL_NEVER
    if i == n then color = COL_LATEST end
    gfx.rect_fill(cx - 1, cy - 1, 3, 3, color)

    if labels[i] then
      local text = tostring(e.loop)
      local tw   = usagi.measure_text(text)
      -- Clamped so the first and last labels stay inside the box rather than
      -- hanging off the ends of the axis.
      local tx   = math.min(math.max(cx - tw / 2, x + 1), x + w - tw - 1)
      gfx.text(text, tx, axis_y + 2, COL_LABEL, 0.8)
    end
  end

  -- The newest loop is the one the player just finished, so it gets a pulsing
  -- ring and its wait spelled out - the graph's headline, with the rest of the
  -- series as the context for it.
  local last   = etas[n]
  local lx, ly = px(n), py(last)
  local pulse  = 0.55 + 0.45 * math.abs(math.sin(usagi.elapsed * 4))
  gfx.circ(lx, ly, 4, COL_LATEST, pulse)

  local text    = M.duration_text(last)
  local speedup = M.speedup_text(etas[n - 1], last)
  if speedup then text = text .. "  " .. speedup end
  local tw = usagi.measure_text(text)
  -- Anchored to whichever side of the point leaves room, and kept off the top
  -- edge, so the callout never runs out of the box or sits under the cursor.
  local tx = lx + 7
  if tx + tw > x + w - 2 then tx = lx - 7 - tw end
  local ty = math.max(ly - line_h - 4, y + 1)
  gfx.text(text, tx + 1, ty + 1, COL_BG)
  gfx.text(text, tx, ty, COL_LATEST)
end

return M
