-- Standalone harness for the loop-end ¥ breakdown. Run with
-- `usagi dev loop_breakdown_dev.lua`. No persistence, no game state - just
-- loop_breakdown.draw fed synthetic loops, plus live knobs for its layout.
--
-- The block is the tightest thing in the game against the modal: at four
-- tracks it nearly fills the panel, and the panel nearly fills the screen. So
-- the harness always reports the measured size against the budget and shows
-- the real modal on M - a tuning pass that only looks at the bare block will
-- happily overflow it.
--
-- Dev keys: LEFT/RIGHT (or N) cycle specs, UP/DOWN pick a layout knob,
-- [ / ] nudge it (SHIFT for x5), M toggles the real modal, R resets.

local loop_breakdown = require "loop_breakdown"
local modal          = require "modal"

-- The shipping ¥ ladder (economy.RANK_YEN). Restated rather than required:
-- economy pulls in persist/ghost/car and expects a live save, which is exactly
-- what this harness exists to do without.
local ZONES          = {
  { rank = "D", yen = 0 },
  { rank = "C", yen = 15 },
  { rank = "B", yen = 30 },
  { rank = "A", yen = 60 },
  { rank = "S", yen = 120 },
}

-- A mark on the ladder: "A" is a rank alone (arrow parked at the center of its
-- zone), "A@0.72" also pins it to a $/sec position along the whole ladder -
-- the form the game passes (track_data.rank_fraction). Zones are equal fifths,
-- so D is 0-0.2, C 0.2-0.4, B 0.4-0.6, A 0.6-0.8, S 0.8-1.
local function mark(code)
  local rank, frac = code:match("^(%a)@?([%d%.]*)$")
  return rank, tonumber(frac)
end

-- Shorthand for a row: "Track 2 A" raced, "Track 2 -" owned but never raced,
-- "Track 2 x" never bought. The optional third code is last loop's mark on the
-- same track, drawn as the small gray arrow.
local function row(label, code, prev)
  local r = { label = label, state = "raced" }
  if code == "-" then
    r.state = "owned"
  elseif code == "x" then
    r.state = "locked"
  else
    r.rank, r.frac = mark(code)
  end
  if prev then
    local rank, frac = mark(prev)
    r.prev = { rank = rank, frac = frac }
  end
  return r
end

-- Each: { name, note, rows }. Worst case first: four tracks is the tallest the
-- block ever gets and the case the modal budget is set by.
local SPECS          = {
  {
    name = "full corridor",
    note = "four tracks, mixed ranks - the tallest/widest real case",
    rows = { row("Track 1", "S"), row("Track 2", "A"), row("Track 3", "B"), row("Track 4", "C") },
  },
  {
    name = "vs last loop",
    note = "gray arrow = last loop: two gained a rank, one crept, one slipped",
    rows = {
      row("Track 1", "S@0.88", "A@0.71"),
      row("Track 2", "A@0.66", "B@0.55"),
      row("Track 3", "B@0.52", "B@0.47"),
      row("Track 4", "C@0.28", "B@0.44"),
    },
  },
  {
    name = "unraced, was raced",
    note = "last loop's mark on rows this loop never touched - the whole nudge",
    rows = {
      row("Track 1", "A@0.74", "A@0.62"),
      row("Track 2", "-", "S@0.9"),
      row("Track 3", "x", "C@0.33"),
      row("Track 4", "x"),
    },
  },
  {
    name = "arrows collide",
    note = "identical to last loop: the white arrow has to survive the overlap",
    rows = { row("Track 1", "A@0.7", "A@0.7"), row("Track 2", "D@0.05", "D@0.05") },
  },
  {
    name = "loop 2",
    note = "the first breakdown the player ever sees",
    rows = { row("Track 1", "C"), row("Track 2", "x"), row("Track 3", "x"), row("Track 4", "x") },
  },
  {
    name = "all D",
    note = "raced everything, banked nothing - the ¥ gap is the whole message",
    rows = { row("Track 1", "D"), row("Track 2", "D"), row("Track 3", "D"), row("Track 4", "D") },
  },
  {
    name = "bought, never raced",
    note = "owned rows: dim ladder, no arrow, dash in the column",
    rows = { row("Track 1", "B"), row("Track 2", "-"), row("Track 3", "-"), row("Track 4", "x") },
  },
  {
    name = "maxed",
    note = "S across the board; four rainbow zones shimmering at once",
    rows = { row("Track 1", "S"), row("Track 2", "S"), row("Track 3", "S"), row("Track 4", "S") },
  },
  {
    name = "single track",
    note = "the minimum: one row over the total",
    rows = { row("Track 1", "A") },
  },
  {
    name = "long labels",
    note = "label column has to grow and squeeze nothing else",
    rows = { row("Nakayama Loop", "A"), row("Wangan Expressway", "S"), row("Track 3", "-") },
  },
  {
    name = "rebalanced ¥",
    note = "four-digit rungs; checks the zone captions don't collide",
    rows = { row("Track 1", "S"), row("Track 2", "A"), row("Track 3", "x") },
    zones = {
      { rank = "D", yen = 0 },
      { rank = "C", yen = 250 },
      { rank = "B", yen = 900 },
      { rank = "A", yen = 2400 },
      { rank = "S", yen = 9999 },
    },
  },
}

-- The layout knobs, in the order the arrow keys walk them.
local KNOBS          = {
  "bar_w", "bar_pad", "arrow_h", "arrow_w", "prev_arrow", "row_gap", "col_gap",
  "zone_gap", "total_gap", "label_scale", "rank_scale", "yen_scale", "value_scale",
}

function _config()
  return {
    name        = "Loop Breakdown Dev",
    game_width  = 640,
    game_height = 352,
  }
end

local function reset()
  State = {
    index = 1,
    knob  = 1,
    modal = false,
  }
  for k, v in pairs(loop_breakdown.DEFAULTS) do loop_breakdown.TUNE[k] = v end
end

function _init()
  reset()
  gfx.shader_set("vhs")
end

local function spec_of(set)
  return { zones = set.zones or ZONES, rows = set.rows }
end

local function cycle(list, i, delta)
  return (i - 1 + delta) % #list + 1
end

local function nudge(delta)
  local key = KNOBS[State.knob]
  -- Scales are multipliers, so they step by 1 and floor at 1; the rest are
  -- pixels and may legitimately go to 0 (row_gap ships at 0).
  local is_scale = key:find("_scale") ~= nil
  local step     = (is_scale or not input.key_held(input.KEY_LSHIFT)) and 1 or 5
  local floor    = is_scale and 1 or 0
  loop_breakdown.TUNE[key] = math.max(floor, loop_breakdown.TUNE[key] + delta * step)
end

function _update(_dt)
  if input.key_pressed(input.KEY_R) then reset() end
  if input.key_pressed(input.KEY_RIGHT) or input.key_pressed(input.KEY_N) then
    State.index = cycle(SPECS, State.index, 1)
  end
  if input.key_pressed(input.KEY_LEFT) then State.index = cycle(SPECS, State.index, -1) end
  if input.key_pressed(input.KEY_DOWN) then State.knob = cycle(KNOBS, State.knob, 1) end
  if input.key_pressed(input.KEY_UP) then State.knob = cycle(KNOBS, State.knob, -1) end
  if input.key_pressed(input.KEY_LBRACKET) then nudge(-1) end
  if input.key_pressed(input.KEY_RBRACKET) then nudge(1) end
  if input.key_pressed(input.KEY_M) then State.modal = not State.modal end
end

-- What the modal has left for the block after its own furniture: title band,
-- a one-line body, the button, the gaps between them and the panel padding.
-- Mirrors modal.lua's layout constants - if that file's paddings move, this
-- number is the thing to re-derive.
local function demo_budget()
  local _, lh   = usagi.measure_text("A")
  local chrome  = 16 * 2          -- PANEL_PAD
      + lh * 3 + 20               -- title + GAP
      + lh * 2 + 20               -- one body line + GAP
      + 20                        -- GAP under the demo
      + lh * 2 + 2 * 2            -- button
  return 640 - 16 * 2, 352 - chrome
end

-- The knob list under the block, two columns so it clears the footer, current
-- value each, selection highlighted.
local function draw_knobs(x, y)
  local per_col = math.ceil(#KNOBS / 2)
  for i, key in ipairs(KNOBS) do
    local sel = i == State.knob
    gfx.text(string.format("%s %-11s %d", sel and ">" or " ", key, loop_breakdown.TUNE[key]),
      x + math.floor((i - 1) / per_col) * 160,
      y + ((i - 1) % per_col) * 12,
      sel and gfx.COLOR_YELLOW or gfx.COLOR_LIGHT_GRAY)
  end
end

function _draw()
  gfx.shader_uniform("u_time", usagi.elapsed)
  gfx.shader_uniform("u_resolution", { usagi.GAME_W, usagi.GAME_H })
  gfx.clear(gfx.COLOR_DARK_BLUE)

  local set             = SPECS[State.index]
  local spec            = spec_of(set)
  local w, h            = loop_breakdown.measure(spec)
  local max_w, max_h    = demo_budget()
  local fits            = w <= max_w and h <= max_h

  if State.modal then
    -- The shipping case: the same panel scenes/buy.lua builds, so the block is
    -- judged at the size and against the furniture it actually ships with.
    modal.draw({
      title  = "TIME'S UP!",
      body   = "Your best rank on each track pays ¥",
      demo   = { w = w, h = h, draw = function(x, y) loop_breakdown.draw(spec, x, y) end },
      button = "CONTINUE",
    })
  else
    -- Bare, centered horizontally at its natural size: pixel-level check of the
    -- zone edges, captions, and arrow placement before the panel is around it.
    loop_breakdown.draw(spec, math.floor((usagi.GAME_W - w) / 2), 64)
  end

  gfx.text(string.format("[%d/%d] %s", State.index, #SPECS, set.name), 8, 8, gfx.COLOR_WHITE)
  gfx.text(set.note, 8, 20, gfx.COLOR_LIGHT_GRAY)
  gfx.text(string.format("block %dx%d   modal budget %dx%d   %s", w, h, max_w, max_h,
      fits and "FITS" or "OVERFLOWS"),
    8, 32, fits and gfx.COLOR_GREEN or gfx.COLOR_RED)

  if not State.modal then draw_knobs(8, 232) end

  gfx.text("<- -> spec   up/down knob   [ ] nudge (shift x5)   M modal   R reset",
    8, usagi.GAME_H - 12, gfx.COLOR_DARK_GRAY)
end
