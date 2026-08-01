-- The loop-end ¥ breakdown: one rank-ladder bar per corridor track showing
-- what every rank on it pays, an arrow on the rank this loop actually earned,
-- and the summed total underneath. The old version was a dotted list of
-- "Track 1 ... ¥60 A" lines, which said what you got but never what you left
-- on the table; the bar puts the earned rank next to the ones above it, so the
-- ¥ gap is the thing you read.
--
-- The bars deliberately echo the race HUD's rank meter (hud.lua draw_bar):
-- same D->S left-to-right ladder, same rank colors, same arrow riding the top
-- edge. The meter teaches the shape mid-race; this cashes it out.
--
-- Pure drawing over a plain spec table - no State, no economy - so
-- loop_breakdown_dev.lua can feed it synthetic loops:
--
--   spec = {
--     zones = { { rank = "D", yen = 0 }, { rank = "C", yen = 15 }, ... },
--     rows  = { { label = "Track 1", state = "raced", rank = "A", frac = 0.72,
--                 prev = { rank = "B", frac = 0.51 } }, ... },
--     total = 60,
--   }
--
-- A row's `state` is "raced" (earned `rank`, gets the arrow and pays), "owned"
-- (bought this loop but never finished a lap) or "locked" (never bought). The
-- last two pay nothing and read as a dimmed ladder with no arrow - still shown,
-- because an empty ladder is exactly the pitch for racing it next loop.
--
-- `frac` is where the row's $/sec landed along the whole ladder (0..1, from
-- track_data.rank_fraction), so the arrow sits at the rate rather than at the
-- middle of the rank it bought - two S runs are not the same run. Optional: a
-- rank-only row parks its arrow at the center of its zone.
--
-- `prev` is the same pair for the previous loop, drawn as a smaller dim arrow
-- under the live one. It's the row's real point once a player has looped a few
-- times: the ladder says what the ranks pay, the white arrow says where this
-- loop landed, and the ghost arrow says whether that was progress. Rows that
-- weren't raced this loop still show theirs - "you were at A here last loop and
-- haven't been back" is exactly the nudge an owned/locked row is for.

local ui   = require "ui"

local M    = {}

-- Layout knobs, in pixels except the *_scale text multipliers. Live values:
-- loop_breakdown_dev mutates this table in place to tune the block on screen,
-- so read through `T` rather than copying fields into locals.
--
-- The whole block has to fit the modal's demo slot, which on a 640x352 screen
-- is about 550x170 once the title, a one-line body, and the button have taken
-- their share (see modal.draw's layout) - and it has to fit at the widest case,
-- four tracks. loop_breakdown_dev prints the measured size against that budget;
-- keep an eye on it when tuning these.
local T    = {
  bar_w       = 400, -- ladder length; the panel is sized around it
  bar_pad     = 4,   -- vertical padding inside a bar, around its tallest ink
  arrow_h     = 8,   -- room above each bar for the earned-rank arrow
  arrow_w     = 6,   -- arrow half-width at its base
  prev_arrow  = 3,   -- half-width of the previous loop's (smaller) arrow
  prev_gap    = 3,   -- between that arrow and its "(last loop)" caption
  row_gap     = 0,   -- extra space between rows (the arrow already separates)
  col_gap     = 10,  -- between the label / bar / value columns
  zone_gap    = 3,   -- between a zone's rank letter and its ¥ amount
  total_gap   = 5,   -- above and below the divider over the total row
  label_scale = 2,
  rank_scale  = 2,
  yen_scale   = 1,
  value_scale = 2,
}
M.TUNE     = T

-- Snapshot of the shipping values, so the dev screen's reset doesn't have to
-- restate them (and so a tuning session can always get back).
M.DEFAULTS = {}
for k, v in pairs(T) do M.DEFAULTS[k] = v end

-- Segments drawn across the earned zone; also the shimmer stride that gives an
-- S zone its rainbow, same as the HUD meter's.
local ZONE_STEPS  = 8

-- Caption on the previous loop's arrow, drawn once for the whole table.
local PREV_LABEL  = "last loop"

-- Row alpha by state: an unraced ladder is still legible, a locked one reads
-- as background.
local STATE_ALPHA = { raced = 1, owned = 0.7, locked = 0.45 }

-- Fraction of the font's line height its glyphs actually ink, top-aligned
-- (monogram is a 5x7 face in a 12px line box). Bars are sized and text is
-- centered off the ink rather than the line box, which would hang a third of
-- every bar below the letters as dead space.
local INK_RATIO   = 7 / 12

local function text_w(s, scale)
  return usagi.measure_text(s) * scale
end

-- Font line height from a known glyph (measure_text's height is only
-- meaningful for single-line input).
local function line_h()
  local _, h = usagi.measure_text("A")
  return h
end

-- Inked height of one line of text at `scale`.
local function ink_h(scale)
  return math.floor(line_h() * scale * INK_RATIO)
end

local function yen_text(n)
  return ui.YEN_CHAR .. n
end

-- ¥ a row banks: its earned rank's rung, or nil when it earned nothing (never
-- raced, never bought, or a rank the ladder doesn't price).
local function row_yen(spec, row)
  if row.state ~= "raced" or not row.rank then return nil end
  for _, z in ipairs(spec.zones) do
    if z.rank == row.rank then return z.yen end
  end
  return nil
end

-- The right-column text for a row: what it banked, or a dash.
function M.row_value(spec, row)
  local yen = row_yen(spec, row)
  return yen and yen_text(yen) or "--"
end

-- Total the spec's rows bank. `spec.total` wins when given (the game passes the
-- number it actually banked); this is the fallback so a dev spec can just list
-- rows and let the sum fall out.
function M.total(spec)
  if spec.total then return spec.total end
  local sum = 0
  for _, row in ipairs(spec.rows) do sum = sum + (row_yen(spec, row) or 0) end
  return sum
end

-- Block size plus the internal column metrics the draw needs, so measure and
-- draw can't disagree about where the columns start. Returns w, h, metrics.
function M.measure(spec)
  local label_w = 0
  local value_w = text_w(yen_text(M.total(spec)), T.value_scale)
  for _, row in ipairs(spec.rows) do
    label_w = math.max(label_w, text_w(row.label, T.label_scale))
    value_w = math.max(value_w, text_w(M.row_value(spec, row), T.value_scale))
  end
  -- The "Total" caption hangs off the bar's right edge, so it can't widen the
  -- block; only the label and value columns can.
  local bar_h = ink_h(T.rank_scale) + T.bar_pad * 2
  local row_h = T.arrow_h + bar_h
  local n     = #spec.rows
  local w     = label_w + T.col_gap + T.bar_w + T.col_gap + value_w
  local h     = n * row_h + math.max(0, n - 1) * T.row_gap
      + T.total_gap * 2 + 1 + ink_h(T.value_scale)
  return w, h, { label_w = label_w, value_w = value_w, bar_h = bar_h, row_h = row_h }
end

-- Left/right pixel edges of zone `i` of `n`, snapped to whole pixels so the
-- half-transparent fills butt exactly (an overlap double-blends into a tick
-- line, a gap exposes the shadow - same constraint as the HUD meter).
local function zone_edges(bar_x, i, n)
  return math.floor(bar_x + (i - 1) / n * T.bar_w + 0.5),
      math.floor(bar_x + i / n * T.bar_w + 0.5)
end

-- One zone: its fill, then its "A ¥60" caption centered on it. The earned zone
-- is filled in its rank color with a white caption (a rank-colored letter would
-- vanish into its own fill); the rest stay dark with the rank letter itself
-- carrying the color, which is where the D->S ladder stays legible at a glance.
local function draw_zone(z, x0, x1, top, bar_h, earned, alpha)
  if earned then
    for s = 1, ZONE_STEPS do
      local sx0 = x0 + math.floor((x1 - x0) * (s - 1) / ZONE_STEPS + 0.5)
      local sx1 = x0 + math.floor((x1 - x0) * s / ZONE_STEPS + 0.5)
      gfx.rect_fill(sx0, top, sx1 - sx0, bar_h, ui.rank_color(z.rank, s), 0.75)
    end
  else
    gfx.rect_fill(x0, top, x1 - x0, bar_h, gfx.COLOR_DARK_GRAY, 0.5 * alpha)
  end

  local amount       = yen_text(z.yen)
  local rank_w       = text_w(z.rank, T.rank_scale)
  local amount_w     = text_w(amount, T.yen_scale)
  local cx           = math.floor((x0 + x1 - (rank_w + T.zone_gap + amount_w)) / 2)
  local rank_y       = top + T.bar_pad
  -- The smaller ¥ amount sits on the rank letter's baseline rather than its
  -- top, so the two scales read as one caption.
  local amount_y     = rank_y + ink_h(T.rank_scale) - ink_h(T.yen_scale)

  local letter_color = earned and gfx.COLOR_WHITE or ui.rank_color(z.rank, 0)
  local amount_color = earned and gfx.COLOR_WHITE or gfx.COLOR_LIGHT_GRAY
  local text_alpha   = earned and 1 or 0.85 * alpha

  gfx.text_ex(z.rank, cx, rank_y, T.rank_scale, 0, letter_color, text_alpha)
  ui.coin_text(amount, cx + rank_w + T.zone_gap, amount_y, T.yen_scale, amount_color, text_alpha)
end

-- Arrow riding the top edge of the bar over the earned zone, pointing down at
-- it - the same shape the HUD needle wears, parked instead of sweeping.
local function draw_arrow(cx, top, w, color, alpha)
  gfx.tri_fill(cx - w + 1, top - T.arrow_h + 1, cx + w + 1,
    top - T.arrow_h + 1, cx + 1, top + 1, gfx.COLOR_BLACK, 0.5 * alpha)
  gfx.tri_fill(cx - w, top - T.arrow_h, cx + w, top - T.arrow_h,
    cx, top, color, alpha)
end

-- Names the gray arrow, once per table (see M.draw) - four copies would be
-- four times the ink for one fact. Rides the arrow band beside its arrow, at
-- the smallest scale there is: the caption is a key, not a column.
--
-- It prefers the side of the arrow that doesn't hold this loop's white one, and
-- takes the other when that one would run off the bar; when neither fits inside
-- the bar it draws nothing and returns false, and the caller offers the caption
-- to the next row with a ghost arrow rather than hanging it off the ladder it's
-- explaining.
local function draw_prev_label(bar_x, prev_x, cur_x, top)
  local w = text_w(PREV_LABEL, 1)

  -- Inside the bar and clear of this loop's arrow.
  local function fits(x0)
    if x0 < bar_x or x0 + w > bar_x + T.bar_w then return false end
    return not (cur_x and x0 <= cur_x + T.arrow_w and x0 + w >= cur_x - T.arrow_w)
  end

  local left  = prev_x - T.prev_arrow - T.prev_gap - w
  local right = prev_x + T.prev_arrow + T.prev_gap
  -- Away from the white arrow first, so the caption reads as belonging to the
  -- gray one even before the colors are told apart.
  local first, second = left, right
  if cur_x and cur_x < prev_x then first, second = right, left end

  local x = (fits(first) and first) or (fits(second) and second) or nil
  if not x then return false end
  gfx.text_ex(PREV_LABEL, x, top - T.arrow_h, 1, 0, gfx.COLOR_LIGHT_GRAY, 0.75)
  return true
end

-- Pixel x an arrow points at. `frac` (the row's $/sec position along the whole
-- ladder) when the spec measured one; otherwise the center of the zone `rank`
-- names, which is all a rank-only spec can say. nil when neither is given, or
-- when the rank isn't on this ladder.
local function arrow_x(spec, bar_x, frac, rank)
  if frac then return math.floor(bar_x + frac * T.bar_w + 0.5) end
  if not rank then return nil end
  for i, z in ipairs(spec.zones) do
    if z.rank == rank then
      local x0, x1 = zone_edges(bar_x, i, #spec.zones)
      return math.floor((x0 + x1) / 2)
    end
  end
  return nil
end

local function draw_row(spec, row, x, bar_x, right, top, m, label_prev)
  local alpha   = STATE_ALPHA[row.state] or 1
  local n       = #spec.zones

  -- Label and banked ¥ both center on the bar rather than sitting on its top
  -- edge, so a row reads as one line.
  local label_y = top + math.floor((m.bar_h - ink_h(T.label_scale)) / 2)
  ui.coin_text(row.label, x, label_y, T.label_scale,
    row.state == "locked" and gfx.COLOR_LIGHT_GRAY or gfx.COLOR_WHITE, alpha)

  gfx.rect_fill(bar_x + 1, top + 1, T.bar_w, m.bar_h, gfx.COLOR_BLACK, 0.5)
  for i, z in ipairs(spec.zones) do
    local x0, x1 = zone_edges(bar_x, i, n)
    draw_zone(z, x0, x1, top, m.bar_h, row.state == "raced" and z.rank == row.rank, alpha)
  end

  -- Last loop first, so this loop's arrow is the one that stays whole where the
  -- two land on top of each other (no progress, which is a reading of its own).
  -- Gray and half-size: it's the mark being measured against, not the result.
  local prev_x  = row.prev and arrow_x(spec, bar_x, row.prev.frac, row.prev.rank)
  local cur_x   = row.state == "raced" and arrow_x(spec, bar_x, row.frac, row.rank) or nil
  local labeled = false
  if prev_x then
    draw_arrow(prev_x, top, T.prev_arrow, gfx.COLOR_LIGHT_GRAY, 0.75)
    labeled = label_prev and draw_prev_label(bar_x, prev_x, cur_x, top)
  end
  if cur_x then draw_arrow(cur_x, top, T.arrow_w, gfx.COLOR_WHITE, 1) end

  -- End caps only; the zone boundaries read from the color changes.
  for _, bx in ipairs({ bar_x, bar_x + T.bar_w }) do
    gfx.line_ex(bx + 1, top, bx + 1, top + m.bar_h + 2, 1, gfx.COLOR_BLACK, 0.5)
    gfx.line_ex(bx, top - 1, bx, top + m.bar_h + 1, 1, gfx.COLOR_WHITE, 0.5)
  end

  -- Banked ¥ in the right column, tinted with the rank that earned it so the
  -- number and the lit zone read as the same fact.
  local value = M.row_value(spec, row)
  local v_y   = top + math.floor((m.bar_h - ink_h(T.value_scale)) / 2)
  local color = (row.state == "raced" and row.rank) and ui.rank_color(row.rank, 0)
      or gfx.COLOR_LIGHT_GRAY
  ui.coin_text(value, right - text_w(value, T.value_scale), v_y, T.value_scale, color, alpha)

  -- Whether the caption landed, so M.draw can pass it on if it didn't.
  return labeled
end

-- Draws the whole block with its top-left at (x, y). Size it with M.measure.
function M.draw(spec, x, y)
  local w, _, m = M.measure(spec)
  local bar_x   = x + m.label_w + T.col_gap
  local right   = x + w

  -- Only the topmost ghost arrow with room beside it is captioned; the rest are
  -- the same arrow and read off it.
  local labeled = false
  local row_y   = y
  for _, row in ipairs(spec.rows) do
    labeled = draw_row(spec, row, x, bar_x, right, row_y + T.arrow_h, m, not labeled) or labeled
    row_y = row_y + m.row_h + T.row_gap
  end

  -- Divider + total: the raw sum of the column above it, which is the number
  -- the skill tree is about to be handed.
  local div_y = row_y - (#spec.rows > 0 and T.row_gap or 0) + T.total_gap
  gfx.rect_fill(x, div_y, w, 1, gfx.COLOR_LIGHT_GRAY, 0.6)

  local total_y = div_y + 1 + T.total_gap
  local caption = "Total"
  ui.coin_text(caption, bar_x + T.bar_w - text_w(caption, T.value_scale), total_y,
    T.value_scale, gfx.COLOR_LIGHT_GRAY)

  local total = yen_text(M.total(spec))
  ui.coin_text(total, right - text_w(total, T.value_scale), total_y, T.value_scale,
    gfx.COLOR_WHITE)
end

return M
