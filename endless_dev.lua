-- Endless-lap feel harness. Run with `usagi dev endless_dev.lua`.
-- See docs/endless-mode-plan.md -- this exists to answer one question: does
-- dodging oncoming ghosts of your own previous lap, on a loop you never stop
-- driving, feel good -- a hit ends the run outright, so ghosts are a hazard,
-- not a payout to farm.
--
-- Forward track 3 (T cycles to any other authored track, clearing session
-- state since ghosts, coins and the promoted line are all track-shaped),
-- gates off by default. N ghosts, evenly spaced, all
-- replaying your last completed lap -- retrograde by default (same_dir flips
-- them to run with the player instead), at ghost_speed x real time -- phase
-- wraps seamlessly on the closed loop, so the whole field persists for the
-- whole session instead of retiring. Before the first lap rolls over
-- there's no recorded lap yet, so ghosts start out replaying the track's
-- captured reference lap (data/ref_<id>.json) instead of the field being
-- empty. Promoted at rollover only if it beats the stored $/sec rate, so a
-- scruffy lap can't haunt the next one; P swaps to replacing wholesale every
-- lap (even a worse one) for comparison.
--
-- A separate pace ghost (pace_ghost knob) also runs the promoted line the
-- whole time, phased to the player's own lap clock rather than looping
-- independently, so it shows where the promoted lap was at the same elapsed
-- time -- a pure reference, not part of the hazard field: no contact, no
-- payout, car-sized instead of hit-radius-sized.
--
-- It is a harness, not a feature. No persist, no economy, no rank ladder, no
-- save. Cash is a local counter; payouts are local knobs seeded from track 3's
-- authored `pay = 45`. Reuses car, road, gates, track_data, ghost (sample_at
-- only) and popups unchanged; the HUD and coin field are the harness's own,
-- since hud.lua and road.draw_coins are welded to the real economy.
--
--   arrows / BTN1-3  drive
--   R                restart session (cash, ghosts, coins, laps, recording)
--   T                next track (LSHIFT for previous) -- restarts the session
--   H                toggle gates (default off)
--   P                toggle promotion rule (every lap <-> only if faster)
--   [ ]              remove / add a ghost (0..16)
--   N / B            next / previous tuning knob
--   , .              nudge knob (LSHIFT for x5)
--   0                restore authored defaults
--   `                toggle debug HUD/status/knobs/hint text

local car               = require "car"
local gates             = require "gates"
local ghost             = require "ghost"
local popups            = require "popups"
local reference         = require "reference"
local road              = require "road"
local track_data        = require "track_data"

local START_TRACK_ID    = "track3"
local MAX_GHOSTS        = 50
-- Lookahead used to read a ghost's *travel* direction off its line. Small
-- enough to be the local tangent, large enough to clear sample_at's lerp
-- noise between distance-downsampled reference points.
local HEADING_DT        = 0.05
local LAST_LAPS_KEPT    = 5
-- Assumed pace (px/s) for timestamping ideal_line's checkpoint-polyline
-- fallback (no captured reference lap for the track) -- roughly the mid-spec
-- car's top speed (TOP_VEL_BASE 120 + level 2 * TOP_VEL_STEP 50).
local IDEAL_LINE_SPEED  = 220
-- Keep hazard ghosts off the checkpoint line: on a closed loop, "near the
-- start" and "near the end" of the lap are the same neighborhood (phase 0),
-- since the line wraps seamlessly there. Measured in car lengths of actual
-- arc length along the line, so it's the same physical buffer regardless of
-- which lap (or the ideal_line fallback) got promoted, or how fast the car
-- happened to be moving through there.
local START_GAP_LENGTHS = 3

local COIN_SPRITE       = 4
local COIN_BOB_AMP      = 0.6
local COIN_BOB_HZ       = 1.5

-- How long the post-rollover $/sec-delta readout stays up, and how much of
-- that is a fade-out tail rather than solid.
local RATE_FLASH_TIME   = 1.5
local RATE_FLASH_FADE   = 0.4

-- Post-rollover countdown: the world holds still for COUNT_HOLD showing "1",
-- then unfreezes and "GO" lingers for COUNT_GO. One digit only -- this is a
-- beat to mark the lap boundary, not a real grid start.
local COUNT_HOLD        = 0.7
local COUNT_GO          = 0.5

-- Contact/payout knobs, all live-tunable, in the shape reverse_ghosts_dev's
-- TUNE/DEFAULTS uses: DEFAULTS is the authored start, TUNE is what the game
-- reads, so R (session restart) doesn't touch these and 0 restores them.
-- Ghost contact is a hazard by default: a hit ends the loop outright, so
-- there's no hit_pay/cooldown/combo to tune, only whether it's closing-only
-- and how forgiving the hit radius is. boost_on_hit flips that to a speed
-- pickup instead (see contact()), which is where boost_amount and boost_pay
-- come in -- boost_pay is the cash awarded per boosted hit, paid as "coin"
-- kind so it folds into the existing coin_cash tally.
-- hitstop is a brief effect.hitstop punch shared by rollover (loop finished)
-- and ghost contact (boosted or run-ending), marking each as a beat.
local DEFAULTS          = {
  cp_pay       = 45,
  coin_pay     = 25,
  hit_radius   = 25,
  spawn_grace  = 0,
  head_on_only = false,
  coin_radius  = 10,
  max_coins    = 10,
  ghosts       = 3,
  rate_window  = 10,
  line_alpha   = 0,
  ghost_alpha  = 0.15,
  hitstop      = 0,
  same_dir     = true,
  ghost_speed  = 0,
  boost_on_hit = true,
  boost_amount = 50,
  boost_pay    = 5,
  pace_ghost   = true,
}

local TUNE              = {}

local KNOBS             = {
  { key = "cp_pay",       step = 1,    min = 0, fmt = "%.0f" },
  { key = "coin_pay",     step = 1,    min = 0, fmt = "%.0f" },
  { key = "hit_radius",   step = 1,    min = 1, fmt = "%.0f" },
  { key = "spawn_grace",  step = 0.25, min = 0, fmt = "%.2f" },
  { key = "head_on_only", bool = true },
  { key = "coin_radius",  step = 1,    min = 1, fmt = "%.0f" },
  { key = "max_coins",    step = 1,    min = 0, max = 20,         fmt = "%.0f" },
  { key = "ghosts",       step = 1,    min = 0, max = MAX_GHOSTS, fmt = "%.0f" },
  { key = "rate_window",  step = 1,    min = 1, fmt = "%.0f" },
  { key = "line_alpha",   step = 0.05, min = 0, max = 1,          fmt = "%.2f" },
  { key = "ghost_alpha",  step = 0.05, min = 0, max = 1,          fmt = "%.2f" },
  { key = "hitstop",      step = 0.01, min = 0, fmt = "%.3f" },
  { key = "same_dir",     bool = true },
  { key = "ghost_speed",  step = 0.05, min = 0, max = 3,          fmt = "%.2f" },
  { key = "boost_on_hit", bool = true },
  { key = "boost_amount", step = 10,   min = 0, fmt = "%.0f" },
  { key = "boost_pay",    step = 5,    min = 0, fmt = "%.0f" },
  { key = "pace_ghost",   bool = true },
}

function _config()
  return {
    name        = "Endless Dev",
    game_width  = 640,
    game_height = 352,
  }
end

local function tdata()
  return track_data.TRACKS[State.track_id]
end

local function pay(amount, kind, x, y)
  State.cash     = State.cash + amount
  State.lap_cash = State.lap_cash + amount
  if kind == "cp" then
    State.cp_cash     = State.cp_cash + amount
    State.lap_cp_cash = State.lap_cp_cash + amount
  elseif kind == "coin" then
    State.coin_cash     = State.coin_cash + amount
    State.lap_coin_cash = State.lap_coin_cash + amount
  end
  State.cash_events[#State.cash_events + 1] = { t = State.time, amount = amount }
  popups.spawn({ amount = amount, x = x, y = y })
  sfx.play("coin")
end

-- Drops cash events older than the rolling window so rolling_rate's sum stays
-- O(window) instead of O(session).
local function trim_cash_events()
  local events = State.cash_events
  local i      = 1
  while i <= #events do
    if State.time - events[i].t > TUNE.rate_window then
      table.remove(events, i)
    else
      i = i + 1
    end
  end
end

local function coin_taken(col, row)
  for _, c in ipairs(State.coins) do
    if c.col == col and c.row == row then return true end
  end
  return false
end

-- Top up to TUNE.max_coins total, spawning only the shortfall -- never a flat
-- +N -- so uncollected coins persist across laps by design. Slots come from
-- track_data's own authored `coins` list for the track (the real race's
-- lap-1 gold set) instead of random tiles, so a collected coin always
-- refreshes back at one of those same track-defined spots. The slot list's
-- fixed size (State.coin_slots, set in restart_session) caps the field at
-- that track's authored count even if TUNE.max_coins is nudged higher.
local function top_up_coins()
  local need = TUNE.max_coins - #State.coins
  for _, slot in ipairs(State.coin_slots) do
    if need <= 0 then break end
    if not coin_taken(slot.col, slot.row) then
      State.coins[#State.coins + 1] = { col = slot.col, row = slot.row }
      need = need - 1
    end
  end
end

-- Plain box-ish overlap via a circle on the car center, radius a live knob so
-- a magnet-ish feel can be tried (there's no upgrade state here to drive a
-- real magnet).
local function coins_update()
  local c  = State.car
  local cx = c.x + car.SIZE / 2
  local cy = c.y + car.SIZE / 2
  local i  = 1
  while i <= #State.coins do
    local coin = State.coins[i]
    local rect = track_data.coin_rect(coin)
    if util.circ_rect_overlap({ x = cx, y = cy, r = TUNE.coin_radius }, rect) then
      table.remove(State.coins, i)
      pay(TUNE.coin_pay, "coin", cx, c.y)
    else
      i = i + 1
    end
  end
end

-- Placeholder line for before the first lap rolls over, so the ghost field
-- isn't empty for a lap. Prefers the track's captured reference lap
-- (data/ref_<id>.json via reference.lua, the same clean driven line the race
-- rank meter uses) -- reference.lua's points are already {t,x,y} in the same
-- top-left car-position space _update records into State.rec, so they drop in
-- unchanged; sample_at just needs angle/drift filled in since the reference
-- schema doesn't carry them. Falls back to a straight spawn -> each
-- checkpoint's center -> spawn polyline for a track with no reference
-- captured -- a cruder approximation that can cut corners a real lap
-- wouldn't, but keeps ghosts present rather than absent.
-- rollover() replaces whichever one wholesale with the player's own first lap.
local function ideal_line(t)
  local ref = reference.load(State.track_id)
  if ref then
    local line = {}
    for i, p in ipairs(ref.points) do
      line[i] = { t = p.t, x = p.x, y = p.y, angle = 0, drift = false }
    end
    return line
  end

  local ts   = track_data.tile_size
  local half = car.SIZE / 2
  local pts  = { { x = t.spawn.col * ts, y = t.spawn.row * ts } }
  for _, cp in ipairs(t.checkpoints) do
    local r = track_data.checkpoint_rect(cp)
    pts[#pts + 1] = { x = r.x + r.w / 2 - half, y = r.y + r.h / 2 - half }
  end
  pts[#pts + 1] = pts[1]

  local line = {}
  local dist = 0
  for i, p in ipairs(pts) do
    if i > 1 then
      local prev = pts[i - 1]
      dist = dist + math.sqrt((p.x - prev.x) ^ 2 + (p.y - prev.y) ^ 2)
    end
    line[i] = { t = dist / IDEAL_LINE_SPEED, x = p.x, y = p.y, angle = 0, drift = false }
  end
  return line
end

-- Time along the line at cumulative distance `d`, by walking State.cum (the
-- per-point cumulative distance table built in set_line) and lerping the
-- bracketing points' timestamps. This is what turns an arc-length placement
-- into a phase the rest of the ghost code can sample with.
local function time_at_dist(d)
  local cum, line = State.cum, State.line
  if not cum or #cum < 2 then return 0 end
  d = math.max(0, math.min(cum[#cum], d))
  for i = 2, #cum do
    if cum[i] >= d then
      local span = cum[i] - cum[i - 1]
      local f    = span > 0 and (d - cum[i - 1]) / span or 0
      return line[i - 1].t + (line[i].t - line[i - 1].t) * f
    end
  end
  return line[#line].t
end

-- Lays the field out by *distance* along the line, not by time. Time-even
-- offsets clump in space wherever the promoted lap was slow (corners eat lap
-- time, so they'd collect ghosts) and thin out on the straights; spacing by
-- arc length puts the same number of car lengths between neighbours
-- everywhere. The start gap is a distance too -- START_GAP_LENGTHS car
-- lengths -- carved off both ends of the loop, leaving `range` as the
-- remaining best line the ghosts actually get dispersed through. Offsets are
-- stored as times (phases) since that's what ghost_pose samples with.
-- Recomputed on every new line (set_line, i.e. a promoted best lap) and
-- whenever the ghost count changes, so a re-laid field always reflects the
-- line it's actually riding.
local function set_offsets()
  State.offsets = {}
  local total   = State.cum and State.cum[#State.cum] or 0
  local n       = TUNE.ghosts
  if total <= 0 or n <= 0 then return end
  local gap   = math.min(START_GAP_LENGTHS * car.SIZE, total / 2)
  local range = total - 2 * gap
  for i = 1, n do
    local d = gap + (range > 0 and (i - 0.5) / n * range or 0)
    State.offsets[i] = time_at_dist(d)
  end
end

-- Installs a new ghost line, rebuilds its cumulative-distance table, and
-- re-lays the ghost field on it.
local function set_line(line)
  State.line   = line
  State.period = line[#line].t
  State.cum    = { 0 }
  for i = 2, #line do
    local a, b = line[i - 1], line[i]
    State.cum[i] = State.cum[i - 1] + math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
  end
  set_offsets()
end

-- Pose plus travel heading of ghost instance `i`. Wrapping, not retiring:
-- phase walks through the recorded lap at TUNE.ghost_speed x real time and
-- wraps seamlessly because the lap is a closed loop (start ~= end).
-- Phase is driven by State.lap_t, not session time, so the field re-lays
-- itself at every rollover: at lap_t 0 ghost i sits on its arc-length offset
-- (State.offsets, laid out by set_offsets), and with the default ghost_speed
-- of 0 it simply stays there for the whole lap.
-- The offsets keep the whole field off phase 0 by START_GAP_LENGTHS car
-- lengths on both sides: the car respawns on the line's own start pose each
-- lap, so a ghost right at phase 0 would be sitting on top of the player at
-- every GO -- a free boost, or an instant run-ender with boost_on_hit off --
-- and since the loop wraps seamlessly, phase 0 is simultaneously the "end" of
-- the lap too, so one symmetric gap there covers both.
-- TUNE.same_dir off (default) is retrograde -- phase = (offset - moved),
-- heading flipped by pi -- so ghosts run head-on into the player as before.
-- On, phase = (offset + moved) with no flip, so ghosts run the lap the same
-- way the player drove it. Heading is the local tangent (small lookahead);
-- the lookahead step itself isn't scaled by ghost_speed, since it only needs
-- two nearby points on the line to read a direction, not to move in time.
local function ghost_pose(i)
  local line = State.line
  if not line or State.period <= 0 then return nil end
  local offset = State.offsets and State.offsets[i]
  if not offset then return nil end
  local moved = State.lap_t * TUNE.ghost_speed
  local phase = TUNE.same_dir and ((offset + moved) % State.period) or ((offset - moved) % State.period)
  local s     = ghost.sample_at(line, phase)
  if not s then return nil end
  local phase2 = (phase + HEADING_DT) % State.period
  local s2     = ghost.sample_at(line, phase2)
  local flip   = TUNE.same_dir and 0 or math.pi
  local head   = s.angle + flip
  if s2 then
    local dx, dy = s2.x - s.x, s2.y - s.y
    if dx * dx + dy * dy > 0.01 then head = math.atan(dy, dx) + flip end
  end
  return { x = s.x, y = s.y, head = head }
end

-- Pose of the non-interactive pace ghost: the promoted line sampled at the
-- player's own State.lap_t, so it always shows where that lap was at the
-- same elapsed time -- forward, real-time pace, no TUNE.ghost_speed/same_dir
-- involved, since it's a straight reference rather than part of the field.
local function pace_ghost_pose()
  local line = State.line
  if not line or State.period <= 0 then return nil end
  local phase = State.lap_t % State.period
  local s     = ghost.sample_at(line, phase)
  if not s then return nil end
  local phase2 = (phase + HEADING_DT) % State.period
  local s2     = ghost.sample_at(line, phase2)
  local head   = s.angle
  if s2 then
    local dx, dy = s2.x - s.x, s2.y - s.y
    if dx * dx + dy * dy > 0.01 then head = math.atan(dy, dx) end
  end
  return { x = s.x, y = s.y, head = head }
end

-- Contact is not collision: the car passes through. Closing-only by default,
-- judged on actual travel (car.vel_angle) so a spun car still reads correctly.
-- A hit ends the loop outright (State.ended) instead of paying out -- ghosts
-- are a hazard to dodge, not a target to farm. TUNE.boost_on_hit swaps that
-- for the opposite bet: a hit shoves the car forward (car.apply_boost) and
-- lets the run continue, so ghosts read as a risky speed pickup instead of a
-- hard fail. Each ghost is worth exactly one hit per lap: a boosted hit marks
-- it State.taken[i], which drops it out of both contact and draw for the rest
-- of the lap, so it reads as a pickup that gets consumed rather than a body
-- the car can sit inside farming boosts. The field comes back whole at
-- rollover. State.touch[i] still edge-detects overlap for the case where a
-- ghost is overlapped but *not* hit (head_on_only, car not closing), so
-- turning into a ghost already inside the car doesn't fire late.
-- State.grace_t counts down after a fresh ghost line appears (rollover) so a
-- ghost that happens to phase in right on top of the car at spawn doesn't
-- insta-end the run before the player can react.
local function contact(dt)
  if State.ended then return end
  if not State.line or State.period <= 0 then return end
  if State.grace_t > 0 then
    State.grace_t = math.max(0, State.grace_t - dt)
    return
  end

  local c    = State.car
  local cx   = c.x + car.SIZE / 2
  local cy   = c.y + car.SIZE / 2
  local r    = TUNE.hit_radius / 2
  local trav = util.vec_from_angle(c.vel_angle, c.vel)

  for i = 1, TUNE.ghosts do
    local g           = not State.taken[i] and ghost_pose(i) or nil
    local overlapping = false
    if g then
      local gx = g.x + car.SIZE / 2
      local gy = g.y + car.SIZE / 2
      overlapping = util.circ_overlap({ x = cx, y = cy, r = r }, { x = gx, y = gy, r = r })
      if overlapping and not State.touch[i] then
        local gv      = util.vec_from_angle(g.head, 1)
        local closing = trav.x * gv.x + trav.y * gv.y < 0
        if closing or not TUNE.head_on_only then
          State.hits     = State.hits + 1
          State.lap_hits = State.lap_hits + 1
          if TUNE.hitstop > 0 then effect.hitstop(TUNE.hitstop) end
          if TUNE.boost_on_hit then
            car.apply_boost(State.car, TUNE.boost_amount)
            if TUNE.boost_pay > 0 then
              pay(TUNE.boost_pay, "coin", cx, cy)
            end
            -- Consumed for the lap, and no longer overlapping anything, since
            -- it stops being drawn or posed at all until rollover.
            State.taken[i] = true
            overlapping    = false
          else
            State.ended    = true
            State.touch[i] = overlapping
            sfx.play("squeal")
            return
          end
        end
      end
    end
    State.touch[i] = overlapping
  end
end

-- Promoted at rollover only if it beats the stored $/sec rate, by default.
-- State.promote_mode "always" switches to replacing wholesale instead:
-- whatever lap just finished becomes the new line, verbatim, even a bad one.
local function rollover()
  local rec      = State.rec
  local lap_rate = State.lap_t > 0 and State.lap_cash / State.lap_t or 0

  if #rec > 1 then
    local prev_rate = State.best_rate
    local promote   = true
    if State.promote_mode == "best" then
      promote = (not State.best_rate) or lap_rate > State.best_rate
    end
    if promote then
      set_line(rec)
      State.best_rate = lap_rate
      State.grace_t   = TUNE.spawn_grace
    end
    if prev_rate then
      local diff = lap_rate - prev_rate
      State.rate_flash = {
        text = string.format("%+.2f $/sec", diff),
        good = diff >= 0,
        t    = RATE_FLASH_TIME,
      }
    end
  end

  State.last_laps[#State.last_laps + 1] = {
    t    = State.lap_t,
    cash = State.lap_cash,
    hits = State.lap_hits,
    rate = lap_rate,
  }
  if #State.last_laps > LAST_LAPS_KEPT then table.remove(State.last_laps, 1) end

  State.lap           = State.lap + 1
  State.lap_t         = 0
  State.lap_cash      = 0
  State.lap_hits      = 0
  State.lap_cp_cash   = 0
  State.lap_coin_cash = 0
  State.rec           = {}
  State.touch         = {}
  State.taken         = {}
  State.count_t       = COUNT_HOLD + COUNT_GO
  -- Every lap is a real grid start: car back on the track's spawn tile, facing
  -- the authored direction, stopped, boosts refilled -- the same car.reset the
  -- session start uses. So a lap's time is always measured from the same pose,
  -- and nothing (speed, drift, leftover boosts) carries across the line.
  car.reset(State.car, tdata().spawn)
  top_up_coins()
  sfx.play("loop_complete")
  if TUNE.hitstop > 0 then effect.hitstop(TUNE.hitstop) end
end

-- A lap is cross cp1 -> cross cp2 -> rollover, in order like the real race.
local function laps(dt)
  State.lap_t = State.lap_t + dt
  local cps   = tdata().checkpoints
  local rect  = track_data.checkpoint_rect(cps[State.next_cp])
  if util.rect_overlap(car.rect(State.car), rect) then
    pay(TUNE.cp_pay, "cp", State.car.x + car.SIZE / 2, State.car.y)
    State.next_cp = State.next_cp + 1
    if State.next_cp > #cps then
      State.next_cp = 1
      rollover()
    end
  end
end

-- Full reset -- cash, lap counter, ghosts, recording, and a fresh coin roll --
-- so a clean measured window can be run on demand. Knobs (TUNE), gate toggle,
-- and promotion mode are untouched: those are session-spanning choices, not
-- session state. So is the current track (State.track_id) -- R re-derives the
-- line, coins and spawn from whichever track is selected rather than dropping
-- back to START_TRACK_ID, so a restart mid-tuning-pass stays put.
local function restart_session()
  car.reset(State.car, tdata().spawn)
  State.time          = 0
  State.cash          = 0
  State.hits          = 0
  State.cp_cash       = 0
  State.coin_cash     = 0
  State.lap           = 1
  State.next_cp       = 1
  State.lap_t         = 0
  State.lap_cash      = 0
  State.lap_hits      = 0
  State.lap_cp_cash   = 0
  State.lap_coin_cash = 0
  State.ended         = false
  State.count_t       = COUNT_HOLD + COUNT_GO
  State.grace_t       = TUNE.spawn_grace
  State.rec           = {}
  State.touch         = {}
  State.taken         = {}
  State.rate_flash    = nil
  set_line(ideal_line(tdata()))
  State.best_rate   = nil
  State.last_laps   = {}
  State.cash_events = {}
  State.coins       = {}
  State.coin_slots  = {}
  for _, c in ipairs(tdata().coins) do
    State.coin_slots[#State.coin_slots + 1] = { col = c.col, row = c.row }
  end
  top_up_coins()
  popups.clear()
end

-- Step through track_data's visible corridor, wrapping. Everything session
-- state holds -- promoted line, ghost field, coin slots, lap history, cash --
-- is measured on one track's geometry, so a switch is a full restart_session
-- rather than a swap: carrying a track3 line onto track4 would just put ghosts
-- through walls. Knobs (TUNE) survive, same as R, so a tuning pass can be
-- compared across tracks.
local function cycle_track(delta)
  local order = track_data.track_order()
  local at    = 1
  for i, id in ipairs(order) do
    if id == State.track_id then at = i end
  end
  State.track_id = order[(at - 1 + delta) % #order + 1]
  restart_session()
end

local function nudge(delta)
  local k = KNOBS[State.knob]
  if k.bool then
    TUNE[k.key] = not TUNE[k.key]
    return
  end
  local step  = k.step * (input.key_held(input.KEY_LSHIFT) and 5 or 1)
  local v     = TUNE[k.key] + delta * step
  v           = math.max(k.min, k.max and math.min(k.max, v) or v)
  TUNE[k.key] = math.floor(v * 1000 + 0.5) / 1000
end

local function keys()
  if input.key_pressed(input.KEY_BACKTICK) then State.debug_on = not State.debug_on end
  if input.key_pressed(input.KEY_H) then State.gates_on = not State.gates_on end
  if input.key_pressed(input.KEY_P) then
    State.promote_mode = State.promote_mode == "always" and "best" or "always"
  end
  if input.key_pressed(input.KEY_LBRACKET) then TUNE.ghosts = math.max(0, TUNE.ghosts - 1) end
  if input.key_pressed(input.KEY_RBRACKET) then TUNE.ghosts = math.min(MAX_GHOSTS, TUNE.ghosts + 1) end
  if input.key_pressed(input.KEY_N) then State.knob = State.knob % #KNOBS + 1 end
  if input.key_pressed(input.KEY_B) then State.knob = (State.knob - 2) % #KNOBS + 1 end
  if input.key_pressed(input.KEY_COMMA) then nudge(-1) end
  if input.key_pressed(input.KEY_PERIOD) then nudge(1) end
  if input.key_pressed(input.KEY_0) then
    for k, v in pairs(DEFAULTS) do TUNE[k] = v end
  end
  if input.key_pressed(input.KEY_R) then restart_session() end
  if input.key_pressed(input.KEY_T) then
    cycle_track(input.key_held(input.KEY_LSHIFT) and -1 or 1)
  end
  -- [ ] , the ghosts knob and 0 (defaults) can all change the count, and the
  -- field is spaced against it, so re-lay whenever it no longer matches.
  if State.offsets and #State.offsets ~= TUNE.ghosts then set_offsets() end
end

function _init()
  State = {
    car          = car.default_state(),
    track_id     = START_TRACK_ID,
    gates_on     = false,
    promote_mode = "best",
    knob         = 1,
    debug_on     = true,
  }
  -- Mid-spec car: accel 2, top speed 2, drift, drift boost, boost 2. A base
  -- car makes every $/sec reading a speed test rather than a mechanic test.
  car.apply_upgrades(State.car, 2, 1, true, true, 0, true)
  for k, v in pairs(DEFAULTS) do TUNE[k] = v end
  restart_session()
end

-- A ghost hit freezes the run in place (car parked where it died) until R
-- restarts -- only input handling and popup fade-out keep running.
-- The post-rollover countdown freezes the same way for its "1" beat: the lap
-- clock, session clock and ghost phases all hold, so the held frames cost the
-- player nothing in $/sec and the field is where they left it. The "GO" tail
-- runs live -- it's just the readout lingering.
function _update(dt)
  keys()
  if State.ended then
    popups.update(dt)
    return
  end
  if State.count_t > 0 then
    local held    = State.count_t > COUNT_GO
    State.count_t = math.max(0, State.count_t - dt)
    if held then
      popups.update(dt)
      return
    end
  end
  State.time = State.time + dt
  trim_cash_events()

  local t          = tdata()
  local gate_walls = State.gates_on and t.gates and gates.apply_walls(t.gates, State.car, t.map)
  car.update(State.car, dt, t.map)
  if gate_walls then gates.restore_walls(t.map, gate_walls) end

  laps(dt)
  local pose = car.pose(State.car)
  State.rec[#State.rec + 1] = { t = State.lap_t, x = pose.x, y = pose.y, angle = pose.angle, drift = pose.drift }

  coins_update()
  contact(dt)
  popups.update(dt)

  if State.rate_flash then
    State.rate_flash.t = State.rate_flash.t - dt
    if State.rate_flash.t <= 0 then State.rate_flash = nil end
  end
end

local GHOST_TINT                 = gfx.COLOR_PINK
local BOOST_GHOST_TINT           = gfx.COLOR_GREEN
local PACE_GHOST_TINT            = gfx.COLOR_BLUE
local LINE_TINT                  = gfx.COLOR_PEACH
-- Sprite 2's cell in sprites.png (32x64, 2 cols x 4 rows).
local GHOST_SPR_SX, GHOST_SPR_SY = 16, 0

-- The whole loop, constant alpha, frozen until rollover: on a closed loop
-- "the path they will take" is the whole loop, and it can't morph mid-lap
-- without becoming unreadable.
local function draw_race_line()
  local line = State.line
  if not line or #line < 2 or TUNE.line_alpha <= 0 then return end
  local half = car.SIZE / 2
  for i = 2, #line do
    local a, b = line[i - 1], line[i]
    gfx.line(a.x + half, a.y + half, b.x + half, b.y + half, LINE_TINT, TUNE.line_alpha)
  end
end

local function draw_ghosts()
  local tint = TUNE.boost_on_hit and BOOST_GHOST_TINT or GHOST_TINT
  for i = 1, TUNE.ghosts do
    local g = not State.taken[i] and ghost_pose(i) or nil
    if g then
      local sz = TUNE.hit_radius
      local cx = g.x + car.SIZE / 2
      local cy = g.y + car.SIZE / 2
      gfx.sspr_ex(GHOST_SPR_SX, GHOST_SPR_SY, car.SIZE, car.SIZE,
        cx - sz / 2, cy - sz / 2, sz, sz,
        false, false, g.head - math.pi / 2, tint, TUNE.ghost_alpha)
    end
  end
end

-- Non-interactive: car-sized (not TUNE.hit_radius) and skipped entirely by
-- contact(), since it's a pure pace reference rather than part of the field.
local function draw_pace_ghost()
  if not TUNE.pace_ghost then return end
  local g = pace_ghost_pose()
  if not g then return end
  gfx.sspr_ex(GHOST_SPR_SX, GHOST_SPR_SY, car.SIZE, car.SIZE,
    g.x, g.y, car.SIZE, car.SIZE,
    false, false, g.head - math.pi / 2, PACE_GHOST_TINT, TUNE.ghost_alpha)
end

local function draw_coins()
  local ts  = track_data.tile_size
  local bob = math.sin(usagi.elapsed * COIN_BOB_HZ * 2 * math.pi) * COIN_BOB_AMP
  for _, coin in ipairs(State.coins) do
    gfx.spr(COIN_SPRITE, coin.col * ts, coin.row * ts + bob)
  end
end

-- Rolling $/sec over TUNE.rate_window, for the always-on core HUD.
local function rolling_rate()
  local window  = math.max(0.001, math.min(TUNE.rate_window, State.time))
  local rolling = 0
  for _, e in ipairs(State.cash_events) do rolling = rolling + e.amount end
  return rolling / window
end

-- Money and rate: the two numbers worth seeing even with debug info hidden,
-- so they stay up regardless of State.debug_on and are centered rather than
-- pinned to the corner like the rest of the HUD.
local function draw_hud_core(rolling)
  local money_text = string.format("$%.0f", State.cash)
  local mw         = select(1, usagi.measure_text(money_text)) * 3
  local mx         = (usagi.GAME_W - mw) / 2
  gfx.text_ex(money_text, mx + 1, 5, 3, 0, gfx.COLOR_BLACK, 1)
  gfx.text_ex(money_text, mx, 4, 3, 0, gfx.COLOR_GREEN, 1)

  local rate_text = string.format("$%.2f/sec", rolling)
  local rw        = select(1, usagi.measure_text(rate_text))
  gfx.text_ex(rate_text, (usagi.GAME_W - rw) / 2, 27, 1, 0, gfx.COLOR_LIGHT_GRAY, 1)
end

-- Rollover readout: how this lap's $/sec compared to the lap it was (or
-- wasn't) promoted against. Sticks around for RATE_FLASH_TIME, fading out
-- over the last RATE_FLASH_FADE of that.
local function draw_rate_flash()
  local flash = State.rate_flash
  if not flash then return end
  local alpha = math.min(1, flash.t / RATE_FLASH_FADE)
  local color = flash.good and gfx.COLOR_GREEN or gfx.COLOR_RED
  local w     = select(1, usagi.measure_text(flash.text))
  gfx.text_ex(flash.text, (usagi.GAME_W - w) / 2, 37, 1, 0, color, alpha)
end

-- "1" while the world is held, then "GO" fading out over the live tail.
local function draw_countdown()
  if State.count_t <= 0 then return end
  local held  = State.count_t > COUNT_GO
  local text  = held and "1" or "GO"
  local alpha = held and 1 or math.min(1, State.count_t / COUNT_GO)
  local color = held and gfx.COLOR_WHITE or gfx.COLOR_GREEN
  local w, h  = usagi.measure_text(text)
  local scale = 4
  local x     = (usagi.GAME_W - w * scale) / 2
  local y     = (usagi.GAME_H - h * scale) / 2
  gfx.text_ex(text, x + 1, y + 1, scale, 0, gfx.COLOR_BLACK, alpha)
  gfx.text_ex(text, x, y, scale, 0, color, alpha)
end

local function draw_hud_debug()
  local session_rate = State.time > 0 and State.cash / State.time or 0
  local last         = State.last_laps[#State.last_laps]

  gfx.text(string.format("session %.2f/sec   last lap %.2f/sec",
    session_rate, last and last.rate or 0), 6, 37, gfx.COLOR_LIGHT_GRAY)
  gfx.text(string.format("cp $%.0f . coins $%.0f . hits %d",
    State.cp_cash, State.coin_cash, State.hits), 6, 47, gfx.COLOR_LIGHT_GRAY)

  local y = 57
  for i = 1, #State.last_laps do
    local l = State.last_laps[i]
    gfx.text(string.format("lap %d  %.1fs  $/sec %.1f", i, l.t, l.rate), 6, y, gfx.COLOR_DARK_GRAY)
    y = y + 10
  end
end

local function draw_ended()
  if not State.ended then return end
  local msg  = "LOOP ENDED -- press R"
  local w, h = usagi.measure_text(msg)
  local x, y = (usagi.GAME_W - w) / 2, (usagi.GAME_H - h) / 2
  gfx.rect_fill(0, y - 6, usagi.GAME_W, h + 12, gfx.COLOR_BLACK, 0.6)
  gfx.text_ex(msg, x + 1, y + 1, 1, 0, gfx.COLOR_BLACK, 1)
  gfx.text_ex(msg, x, y, 1, 0, gfx.COLOR_PINK, 1)
end

local function draw_status()
  gfx.rect_fill(usagi.GAME_W - 260, 0, 260, 24, gfx.COLOR_BLACK, 0.55)
  gfx.text(string.format("%s   gates %s   promote %s", State.track_id,
    State.gates_on and "on" or "off", State.promote_mode), usagi.GAME_W - 256, 4, gfx.COLOR_WHITE)
  gfx.text(string.format("ghosts %d   lap %d   cp %d/%d   coins %d",
      TUNE.ghosts, State.lap, State.next_cp - 1, #tdata().checkpoints, #State.coins), usagi.GAME_W - 256, 14,
    gfx.COLOR_LIGHT_GRAY)
end

local function draw_knobs()
  local y = usagi.GAME_H - 12 * #KNOBS - 18
  for i, k in ipairs(KNOBS) do
    local v = TUNE[k.key]
    local text
    if k.bool then
      text = v and "on" or "off"
    else
      text = string.format(k.fmt, v)
    end
    local sel = i == State.knob
    gfx.text(string.format("%s %-13s %s", sel and ">" or " ", k.key, text),
      usagi.GAME_W - 160, y + (i - 1) * 12, sel and gfx.COLOR_YELLOW or gfx.COLOR_LIGHT_GRAY)
  end
end

function _draw()
  local t = tdata()
  road.set_palette(false)
  road.draw_track(t.map)

  local cps = t.checkpoints
  for i, cp in ipairs(cps) do
    road.draw_checkpoint(cp, i, i ~= State.next_cp, #cps)
  end

  car.draw_skid_marks(State.car)
  draw_race_line()
  draw_coins()
  draw_ghosts()
  draw_pace_ghost()
  if State.gates_on and t.gates then gates.draw(t.gates, State.car) end
  car.draw_headlights(State.car)
  car.draw_taillights(State.car)
  car.draw_boosts(State.car)
  car.draw_flames(State.car)
  car.draw(State.car)
  popups.draw()

  local rolling = rolling_rate()
  draw_hud_core(rolling)
  draw_rate_flash()
  draw_countdown()
  if State.debug_on then
    draw_hud_debug()
    draw_status()
    draw_knobs()
    gfx.text("R restart  T track  H gates  P promote  [ ] ghosts  N/B knob  , . nudge  0 defaults  ` hide",
      6, usagi.GAME_H - 12, gfx.COLOR_DARK_GRAY)
  end
  draw_ended()
end
