-- Reverse-ghost feel harness. Run with `usagi dev reverse_ghosts_dev.lua`.
-- See docs/reverse-ghosts-plan.md -- this exists to answer two questions and
-- nothing else: does hunting oncoming ghosts feel good to drive, and does
-- ghost count work as a reverse track's difficulty/reward dial?
--
-- Driven on the *reverse* track: track_data.mirrored's twin of the authored
-- layout, gates applied, car starting in reverse gear. That is the whole
-- REVERSE_MODE prototype minus the global flag, so what's felt here is a
-- reverse track as the game would ship one -- trunk-first through the reverse
-- gates, hood-first through the forward ones -- with traffic on it.
--
-- The ghosts come the other way. Mirroring makes a second *place*, not a second
-- lap direction -- the mirrored checkpoints are taken in the same order, so a
-- forward-played line would just run alongside the player -- so oncoming
-- traffic is retrograde playback of the reference lap, mirrored onto this
-- layout. That is the head-on encounter the mechanic is made of. G plays it
-- forward instead, for a same-direction baseline to compare against.
--
-- A run is two laps and then it's over, so every number on screen is measured
-- over the same bounded thing. The ghosts drive that same race rather than
-- recycling a lap: the reference lap is stitched end to end into a multi-lap
-- line, the field is spawned once on the grid, each car drives its two laps
-- once and retires. Nothing here wraps and nothing respawns.
--
-- It is a harness, not a feature. No persist, no economy, no rank ladder: cash
-- is a local counter and the only thing done with it is a $/sec readout, which
-- is what rank would be made of (track_data.rank_for_rate, quoted in the strip
-- so the density curve can be read directly).
--
-- Reuses the real car, road, gates, ghost sampling and popups, so what's felt
-- here is what a shipped reverse track would feel like. No coins: the track's
-- own coin lists are deliberately left off the road, so the $/sec on screen is
-- the ghosts' rate and nothing else. Whether hunting traffic beats sitting on
-- the coin line is a later question and needs a clean baseline first.
--
--   arrows / BTN1-3  drive (throttle is always on; BTN1 brakes, double-tap flips)
--   R                restart the run (3-2-1 countdown, ghosts respaced)
--   1-4 / T          jump to a track / cycle
--   G                traffic direction (oncoming vs same-direction baseline)
--   [ ]              remove / add a reverse ghost (0..32)
--   P                promote the lap just driven to be the ghost line
--   L                reload the reference line (undo a P)
--   N / B            next / previous tuning knob
--   , .              nudge the selected knob (LSHIFT for x5)
--   0                restore the authored knob defaults
--
-- The pause menu is off (`pause_menu = false`) so P and Enter reach the game
-- instead of opening the overlay -- which is also why ESC has to quit by hand.

local car        = require "car"
local dim        = require "dim"
local gates      = require "gates"
local ghost      = require "ghost"
local popups     = require "popups"
local road       = require "road"
local track_data = require "track_data"
local ui         = require "ui"

local MAX_GHOSTS = 32
-- Same 3-count the race scene runs, at the same double-rate tick, so the beat
-- before the flag is the one the real game has.
local COUNT_FROM = 3
-- A run is a fixed two laps and then it's over. Open-ended driving made every
-- readout here a function of how long the tester felt like sitting on the
-- track; a bounded run is what a $/sec number can actually be compared across.
local RACE_LAPS  = 2
-- Lookahead used to read a ghost's *travel* direction off its line. Small
-- enough to be the local tangent, large enough to clear sample_at's lerp noise
-- between distance-downsampled reference points.
local HEADING_DT = 0.05

-- Contact knobs, all live-tunable, in the shape loop_breakdown.TUNE uses:
-- DEFAULTS is the authored start and TUNE is what the game reads, so R
-- restores without a reload.
local DEFAULTS   = {
  -- Circle-vs-circle contact distance in px: each side carries half of it, so
  -- 12 means "centers within 12px".
  hit_radius   = 30,
  -- Require the two to be closing. Judged on actual travel, not gear sign
  -- (same rule gates.blocks uses), so a car that flipped mid-drift reads
  -- correctly and a rear-end tap is worth nothing. On the reverse track that
  -- distinction is the whole scoring rule: the car travels trunk-first all lap,
  -- so only the oncoming half of the field is ever worth points -- and with G
  -- flipped to the same-direction baseline, nothing closes and the run scores
  -- zero, which is the comparison being made.
  head_on_only = true,
  bonus        = 500,
  combo_step   = 0.5,
  combo_secs   = 2.0,
  cooldown     = 1.0,
  -- Seconds of frozen _update on contact. The single biggest lever on whether
  -- this reads as an impact or as driving through fog.
  hitstop      = 0.00,
  -- Visibility, which *is* a difficulty setting here.
  ghost_alpha  = 0.3,
  -- The race line itself, drawn under the traffic. Reading where oncoming
  -- ghosts will be is most of the skill, so how strongly the line is telegraphed
  -- is its own difficulty dial.
  line_alpha   = 0.25,
}

local TUNE       = {}

local KNOBS      = {
  { key = "hit_radius",   step = 1,    min = 1,    fmt = "%.0f" },
  { key = "head_on_only", bool = true },
  { key = "bonus",        step = 50,   min = 0,    fmt = "%.0f" },
  { key = "combo_step",   step = 0.1,  min = 0,    fmt = "%.2f" },
  { key = "combo_secs",   step = 0.25, min = 0.25, fmt = "%.2f" },
  { key = "cooldown",     step = 0.25, min = 0,    fmt = "%.2f" },
  { key = "hitstop",      step = 0.01, min = 0,    fmt = "%.3f" },
  { key = "ghost_alpha",  step = 0.05, min = 0,    max = 1,     fmt = "%.2f" },
  { key = "line_alpha",   step = 0.05, min = 0,    max = 1,     fmt = "%.2f" },
}

function _config()
  return {
    name        = "Reverse Ghosts Dev",
    game_width  = 640,
    game_height = 352,
  }
end

-- The reverse track: the mirrored twin, never M.TRACKS[id]. track_data.mirrored
-- caches, so this is the same table every frame -- which is what lets
-- gates.apply_walls stamp and restore tiles on it, and leaves the authored map
-- untouched.
local function tdata()
  return track_data.mirrored(State.track)
end

-- The recorded reference lap lives in unmirrored coordinates, so it has to be
-- flipped onto this layout or the ghosts drive through walls. Same rule
-- track_data uses for coins and checkpoints -- a box at x spanning w lands at
-- W - x - w -- with the car's own footprint as the width, and the stored angle
-- flipped about the vertical (dx negates, dy doesn't).
--
-- Only the *reference* needs this. A lap driven here and promoted with P was
-- recorded on the mirrored track already and goes to State.base_line as-is, so
-- base_line is always in play-space.
local function mirror_line(line)
  if not line then return nil end
  local w   = tdata().map.width * track_data.tile_size
  local out = {}
  for i, s in ipairs(line) do
    out[i] = {
      t     = s.t,
      x     = w - s.x - car.SIZE,
      y     = s.y,
      angle = math.pi - s.angle,
      drift = s.drift,
    }
  end
  return out
end

-- Ghost start offsets, one per instance, in playback seconds.
--
-- Spacing them evenly in *time* would bunch them wherever the reference lap was
-- slow, which on a track with one long straight and a hairpin is most of the
-- traffic sitting in the hairpin. Even spacing along the line's arc length is
-- what "cars spread around the circuit" means, so the offsets are distances
-- converted back to the times that reach them.
local function rebuild_offsets()
  -- Off the single-lap base, not the stitched race line: an offset is a place
  -- on the circuit, and the stitched line passes every place RACE_LAPS+1 times.
  local line    = State.base_line
  State.offsets = {}
  if not line or #line < 2 then return end

  -- Cumulative distance along the line, parallel to its samples.
  local cum, total = { 0 }, 0
  for i = 2, #line do
    local dx, dy = line[i].x - line[i - 1].x, line[i].y - line[i - 1].y
    total        = total + math.sqrt(dx * dx + dy * dy)
    cum[i]       = total
  end
  if total <= 0 then return end

  -- Walk the samples once, handing out an offset each time the walk passes the
  -- next target distance: the offsets come out sorted, so this stays linear
  -- rather than a search per ghost.
  local n, seg = State.ghosts, 2
  for i = 1, n do
    local want = (i - 1) / n * total
    while seg < #line and cum[seg] < want do seg = seg + 1 end
    local a, b       = line[seg - 1], line[seg]
    local span       = cum[seg] - cum[seg - 1]
    local f          = span > 0 and (want - cum[seg - 1]) / span or 0
    State.offsets[i] = util.lerp(a.t, b.t, f)
  end
end

-- The line a ghost actually drives: the one-lap base laid end to end enough
-- times that every ghost can drive a full RACE_LAPS race from its own grid slot
-- without the playback ever wrapping. A ghost starting a whole lap back needs a
-- lap more line than one starting on the stripe, so that's RACE_LAPS + 1 copies.
--
-- The seam carries no ghost.LAP_PAUSE. That pause exists so a *looping* ghost
-- reads as restarting its lap; a car in the middle of a two-lap race doesn't
-- stop on the start line, and a 0.6s parked ghost in oncoming traffic is a free
-- hit sitting on the racing line. Copies join at `t = lap`, which is where the
-- recorded lap's own last sample is, so lap 2 picks up exactly where lap 1 left.
local function stitch_laps(base, copies)
  if not base or #base < 2 then return base end
  local lap, out = base[#base].t, {}
  for k = 0, copies - 1 do
    -- The first sample of a later copy sits on the previous copy's last sample
    -- (same time, same place on the stripe), so it's dropped rather than
    -- written as a zero-length span.
    for i = (k == 0 and 1 or 2), #base do
      local s       = base[i]
      out[#out + 1] = { t = k * lap + s.t, x = s.x, y = s.y, angle = s.angle, drift = s.drift }
    end
  end
  return out
end

-- Re-derived whenever the track or the base line changes (P and L both swap the
-- base out from under the ghosts).
local function rebuild_line()
  local base     = State.base_line
  -- `lap_dur`, not `lap`: State.lap is the player's lap counter.
  State.lap_dur  = (base and #base > 1) and base[#base].t or 0
  State.line     = stitch_laps(base, RACE_LAPS + 1)
  -- How long a ghost's race lasts: RACE_LAPS laps of driving, the same race the
  -- player is running. Not the stitched line's length -- that extra lap is only
  -- there so the ghosts starting furthest back have line left to drive.
  State.race_dur = RACE_LAPS * State.lap_dur
  rebuild_offsets()
end

-- Back to the grid: car on the spawn, ghosts back at their even spacing (which
-- is what State.time = 0 buys), counters zeroed, countdown armed.
local function restart_race()
  car.reset(State.car, tdata().spawn)
  -- car.reset hands back car.lua's START_GEAR, which is forward because the
  -- global REVERSE_MODE is off -- this harness mirrors one track at a time
  -- instead. Spawn facing is east on the mirrored layout, which points away
  -- from checkpoint 1, so reverse is the gear that pulls off the line toward it
  -- and the gear the first reverse gate expects.
  State.car.gear  = -1
  State.phase     = "countdown"
  State.count     = COUNT_FROM
  State.count_at  = COUNT_FROM
  State.time      = 0
  State.hits      = 0
  State.cash      = 0
  State.combo     = 0
  State.combo_t   = 0
  State.cool      = {}
  State.next_cp   = 1
  State.lap       = 1
  State.race_t    = 0
  State.final     = nil
  State.lap_t     = 0
  State.lap_hits  = 0
  State.lap_cash  = 0
  State.last_lap  = nil
  State.rec       = {}
  State.last_rec  = nil
  popups.clear()
end

local function load_track(id)
  State.track     = id
  -- The clean fast lap is the right default: reverse ghosts should run a good
  -- line. P replaces it with something deliberately awkward when the question
  -- is whether the mechanic depends on traffic being predictable.
  State.base_line = mirror_line(ghost.line_from_reference(id))
  rebuild_line()
  restart_race()
end

function _init()
  State = {
    track  = "track1",
    -- Oncoming: the ghosts drive the circuit the opposite way to the player. G
    -- flips it to forward playback for the same-direction baseline.
    retro  = true,
    ghosts = 1,
    car    = car.default_state(),
    time   = 0,
    knob   = 1,
  }
  -- A fully upgraded car, reverse included, so the flip is available from the
  -- first frame. Testing this on a base car would be testing the wrong thing --
  -- and a reverse track needs the flip to be drivable at all: a reverse gate is
  -- just a wall to a car that can't travel trunk-first (see gates.enabled).
  car.apply_upgrades(State.car, 4, 2, true, true, 5, true)
  for k, v in pairs(DEFAULTS) do TUNE[k] = v end
  load_track("track1")
  gfx.shader_set("vhs")
end

-- Pose plus travel heading of ghost instance `i`, in playback time. Heading
-- comes from the delta between two samples rather than the stored angle
-- because retrograde playback runs the line backwards: the sprite has to point
-- the way it's actually going, and that's also what the head-on test needs.
local function ghost_pose(i)
  local line = State.line
  if not line or State.lap_dur <= 0 then return nil end
  local offset = State.offsets[i]
  if not offset then return nil end
  -- Each ghost drives one two-lap race and is then gone for good: it is spawned
  -- on the grid at State.time 0 and retired RACE_LAPS laps later, and there is
  -- no modulo anywhere in here, so nothing ever restarts a lap or respawns. A
  -- retired ghost is what bounds farming -- it's why max_hits is gone.
  if State.time >= State.race_dur then return nil end
  -- The offset is a place on the grid, not an age, so every ghost drives for
  -- State.time seconds and the whole field pulls off together. Forward playback
  -- starts `offset` into the stitched line; retrograde starts the same distance
  -- back from its end and walks the other way. Both stay inside the stitched
  -- line's RACE_LAPS + 1 laps for the whole race, which is what buys the extra
  -- copy: no wrap is needed to keep a late-grid ghost in bounds.
  local total = (RACE_LAPS + 1) * State.lap_dur
  local t     = State.retro and (total - offset - State.time) or (offset + State.time)
  local t2    = State.retro and (t - HEADING_DT) or (t + HEADING_DT)
  local s     = ghost.sample_at(line, t)
  if not s then return nil end
  local s2   = ghost.sample_at(line, t2)
  local head = State.retro and (s.angle + math.pi) or s.angle
  if s2 then
    local dx, dy = s2.x - s.x, s2.y - s.y
    -- A parked ghost (either end of the line, or the LAP_PAUSE tail) has no
    -- delta to read, so it keeps the stored heading.
    if dx * dx + dy * dy > 0.01 then head = math.atan(dy, dx) end
  end
  return { x = s.x, y = s.y, head = head }
end

-- Contact is not collision: the car passes through. Whether an unhit ghost
-- should cost the player is an open question in the plan, and "solid" is a
-- much bigger change (it interacts with wall decel and could wedge the car).
local function contact(dt)
  if State.combo_t > 0 then
    State.combo_t = math.max(0, State.combo_t - dt)
    if State.combo_t == 0 then State.combo = 0 end
  end
  for i = 1, State.ghosts do
    if State.cool[i] then State.cool[i] = math.max(0, State.cool[i] - dt) end
  end
  if not State.line or State.lap_dur <= 0 then return end

  local c    = State.car
  local cx   = c.x + car.SIZE / 2
  local cy   = c.y + car.SIZE / 2
  local r    = TUNE.hit_radius / 2
  -- The car's real travel, not its facing: a spun car sliding its original
  -- line is still closing on traffic ahead of it. On the reverse track that
  -- gap is the normal case rather than the edge case -- the car spends the
  -- whole lap travelling trunk-first.
  local trav = util.vec_from_angle(c.vel_angle, c.vel)

  for i = 1, State.ghosts do
    if (State.cool[i] or 0) <= 0 then
      local g = ghost_pose(i)
      if g then
        local gx = g.x + car.SIZE / 2
        local gy = g.y + car.SIZE / 2
        if util.circ_overlap({ x = cx, y = cy, r = r }, { x = gx, y = gy, r = r }) then
          local gv      = util.vec_from_angle(g.head, 1)
          local closing = trav.x * gv.x + trav.y * gv.y < 0
          if closing or not TUNE.head_on_only then
            local pay      = TUNE.bonus * (1 + TUNE.combo_step * State.combo)
            State.hits     = State.hits + 1
            State.lap_hits = State.lap_hits + 1
            State.cash     = State.cash + pay
            State.lap_cash = State.lap_cash + pay
            State.combo    = State.combo + 1
            State.combo_t  = TUNE.combo_secs
            State.cool[i]  = TUNE.cooldown
            popups.spawn({ amount = pay, x = gx, y = g.y })
            if TUNE.hitstop > 0 then effect.hitstop(TUNE.hitstop) end
            sfx.play("coin")
          end
        end
      end
    end
  end
end

-- The run's own number, over the full RACE_LAPS rather than over one lap: it's
-- the one a rank would be cut from, and the reason the run is bounded at all.
local function finish_race()
  State.phase = "finished"
  State.final = {
    t    = State.race_t,
    hits = State.hits,
    cash = State.cash,
    rate = State.race_t > 0 and State.cash / State.race_t or 0,
  }
  car.stop_engine(State.car)
  sfx.play("applause")
end

-- Lap tracking, in-order like the real race, so hits-per-lap and $/sec are
-- measured over something comparable rather than over "since you last pressed
-- R". Completing a lap also closes the recording P promotes; completing the
-- last one ends the run.
local function laps(dt)
  State.lap_t  = State.lap_t + dt
  State.race_t = State.race_t + dt
  local cps    = tdata().checkpoints
  local rect   = track_data.checkpoint_rect(cps[State.next_cp])
  if util.rect_overlap(car.rect(State.car), rect) then
    State.next_cp = State.next_cp + 1
    if State.next_cp > #cps then
      State.next_cp  = 1
      State.last_lap = {
        t    = State.lap_t,
        hits = State.lap_hits,
        cash = State.lap_cash,
        rate = State.lap_t > 0 and State.lap_cash / State.lap_t or 0,
      }
      State.lap_t    = 0
      State.lap_hits = 0
      State.lap_cash = 0
      State.last_rec = State.rec
      State.rec      = {}
      if State.lap >= RACE_LAPS then
        finish_race()
      else
        State.lap = State.lap + 1
        sfx.play("loop_complete")
      end
    end
  end
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
  -- Fractional steps accumulate float dust; the knobs are read off the screen.
  TUNE[k.key] = math.floor(v * 1000 + 0.5) / 1000
end

local TRACK_KEYS = { input.KEY_1, input.KEY_2, input.KEY_3, input.KEY_4 }

local function keys()
  for i, key in ipairs(TRACK_KEYS) do
    if input.key_pressed(key) then load_track("track" .. i) end
  end
  if input.key_pressed(input.KEY_T) then
    local order = track_data.track_order()
    for i, id in ipairs(order) do
      if id == State.track then
        load_track(order[i % #order + 1])
        break
      end
    end
  end
  if input.key_pressed(input.KEY_G) then State.retro = not State.retro end
  -- Changing the count changes where every ghost sits, since the spacing is
  -- shares of the same lap: respace immediately rather than at the next restart.
  if input.key_pressed(input.KEY_LBRACKET) then
    State.ghosts = math.max(0, State.ghosts - 1)
    rebuild_offsets()
  end
  if input.key_pressed(input.KEY_RBRACKET) then
    State.ghosts = math.min(MAX_GHOSTS, State.ghosts + 1)
    rebuild_offsets()
  end
  if input.key_pressed(input.KEY_P) then
    local rec = State.last_rec or State.rec
    if rec and #rec > 1 then
      State.base_line = rec
      rebuild_line()
    end
  end
  if input.key_pressed(input.KEY_L) then
    State.base_line = mirror_line(ghost.line_from_reference(State.track))
    rebuild_line()
  end
  if input.key_pressed(input.KEY_N) then State.knob = State.knob % #KNOBS + 1 end
  if input.key_pressed(input.KEY_B) then State.knob = (State.knob - 2) % #KNOBS + 1 end
  if input.key_pressed(input.KEY_COMMA) then nudge(-1) end
  if input.key_pressed(input.KEY_PERIOD) then nudge(1) end
  -- Knob defaults moved off R, which is now the restart: a run that has to be
  -- restarted to be judged is the whole point of the countdown.
  if input.key_pressed(input.KEY_0) then
    for k, v in pairs(DEFAULTS) do TUNE[k] = v end
  end
  if input.key_pressed(input.KEY_R) then restart_race() end
end

-- Same shape as the race scene's countdown: ticked at double rate (so a "3" is
-- half a second) with a sound on each number and GO! on the flag. Nothing else
-- updates while it runs -- car parked, ghosts frozen on their grid.
local function countdown(dt)
  local shown = math.ceil(State.count)
  if shown ~= State.count_at and shown > 0 then
    State.count_at = shown
    if shown <= 3 then sfx.play(tostring(shown)) end
  end
  State.count = State.count - dt * 2
  if State.count <= 0 then
    State.count = 0
    State.phase = "racing"
    sfx.play("go")
  end
end

function _update(dt)
  keys()

  if State.phase == "countdown" then
    countdown(dt)
    popups.update(dt)
    return
  end
  -- Finished holds the board up until R: there's no buy scene to cut to here,
  -- and the run's numbers are the deliverable.
  if State.phase == "finished" then
    popups.update(dt)
    return
  end

  -- Gates, driven exactly the way the race scene drives them: stamped into the
  -- map as walls around car.update and restored after, so the wall collision
  -- and decel the car already has is what a wrong-way gate feels like. The
  -- ghosts pass straight through -- they're playback, not cars.
  local t          = tdata()
  local gate_walls = t.gates and gates.apply_walls(t.gates, State.car, t.map)
  car.update(State.car, dt, t.map)
  if gate_walls then gates.restore_walls(t.map, gate_walls) end

  State.time = State.time + dt
  laps(dt)
  local pose = car.pose(State.car)
  State.rec[#State.rec + 1] = {
    t     = State.lap_t,
    x     = pose.x,
    y     = pose.y,
    angle = pose.angle,
    drift = pose.drift,
  }

  contact(dt)
  popups.update(dt)
end

local GHOST_TINT                 = gfx.COLOR_PINK
local LINE_TINT                  = gfx.COLOR_PEACH
-- Sprite 2's cell in sprites.png (32x64, 2 cols x 4 rows), for sspr_ex below --
-- spr_ex has no scale param, so drawing the hit box means sourcing the same
-- cell manually.
local GHOST_SPR_SX, GHOST_SPR_SY = 16, 0

-- The path the traffic runs, as one translucent ribbon under the ghosts. Where
-- oncoming cars *will* be is the thing being read while driving, and a per-car
-- heading arrow only answers that a car-length ahead. Drawn through the sample
-- centers rather than their top-left corners, so it sits where the ghosts do.
--
-- The single-lap base, not the stitched race line: the stitched copies lie on
-- top of each other, so drawing it would stack line_alpha RACE_LAPS + 1 deep
-- and the knob would stop meaning what it reads.
local function draw_race_line()
  local line = State.base_line
  if not line or #line < 2 or TUNE.line_alpha <= 0 then return end
  local half = car.SIZE / 2
  for i = 2, #line do
    local a, b = line[i - 1], line[i]
    gfx.line(a.x + half, a.y + half, b.x + half, b.y + half, LINE_TINT, TUNE.line_alpha)
  end
end

local function draw_ghosts()
  for i = 1, State.ghosts do
    local g = ghost_pose(i)
    if g then
      -- Drawn at hit_radius size rather than native car.SIZE, so the sprite
      -- itself is the contact box -- what's seen is what util.circ_overlap
      -- actually judges, not a car plus a separate ring around it.
      local sz = TUNE.hit_radius
      local cx = g.x + car.SIZE / 2
      local cy = g.y + car.SIZE / 2
      gfx.sspr_ex(GHOST_SPR_SX, GHOST_SPR_SY, car.SIZE, car.SIZE,
        cx - sz / 2, cy - sz / 2, sz, sz,
        false, false, g.head - math.pi / 2, GHOST_TINT, TUNE.ghost_alpha)
    end
  end
end

local COUNT_COLORS = {
  [3] = gfx.COLOR_PINK,
  [2] = gfx.COLOR_BLUE,
  [1] = gfx.COLOR_YELLOW,
}

local function draw_countdown()
  dim.draw(usagi.GAME_W, usagi.GAME_H)
  local n      = math.ceil(State.count)
  local text   = tostring(n)
  local scale  = 12
  local tw, th = usagi.measure_text(text)
  ui.neon_text(text, math.floor((usagi.GAME_W - tw * scale) / 2),
    math.floor((usagi.GAME_H - th * scale) / 2), scale, {
      colors = { COUNT_COLORS[n] or gfx.COLOR_WHITE },
      shadow = gfx.COLOR_DARK_PURPLE,
      wobble = 0.1,
    })
end

-- The run's board, held until R. Deliberately the same numbers a rank would be
-- cut from, centered so they're readable off a capture.
local function draw_finish()
  local f = State.final
  if not f then return end
  dim.draw(usagi.GAME_W, usagi.GAME_H)
  local scale  = 8
  local tw, th = usagi.measure_text("FINISH")
  local top    = math.floor(usagi.GAME_H / 2 - th * scale)
  ui.neon_text("FINISH", math.floor((usagi.GAME_W - tw * scale) / 2), top, scale, {
    shadow = gfx.COLOR_DARK_PURPLE,
    wobble = 0.12,
  })
  local rows = {
    string.format("%.1fs   %d hits   $%.0f", f.t, f.hits, f.cash),
    string.format("$/sec %.1f   rank %s", f.rate, track_data.rank_for_rate(State.track, f.rate)),
    "R to run it again",
  }
  local colors = { gfx.COLOR_WHITE, gfx.COLOR_GREEN, gfx.COLOR_LIGHT_GRAY }
  for i, row in ipairs(rows) do
    local w = usagi.measure_text(row)
    gfx.text(row, math.floor((usagi.GAME_W - w) / 2), top + th * scale + 8 + (i - 1) * 12, colors[i])
  end
end

local function stat_line(y, text, color)
  gfx.text(text, 6, y, color or gfx.COLOR_WHITE)
end

local function draw_stats()
  -- Over the whole run, not the current lap: the run is the bounded thing, so
  -- it's the rate that can be compared between ghost counts.
  local rate = State.race_t > 0 and State.cash / State.race_t or 0
  local last = State.last_lap
  -- Seconds of ghost left in the run. The field is spawned once and pulls off
  -- after RACE_LAPS of the line, so a player slower than the reference drives
  -- the tail of the run on an empty track -- which has to be visible, since it
  -- shows up in $/sec as a rate that decays rather than as fewer hits.
  local left = math.max(0, State.race_dur - State.time)
  gfx.rect_fill(0, 0, 340, 52, gfx.COLOR_BLACK, 0.55)
  -- "traffic" rather than "retro": on the reverse track the interesting
  -- statement is which way the ghosts run, not which way the tape plays.
  stat_line(4, string.format("%s rev   traffic %s   ghosts %d   %s",
    State.track, State.retro and "oncoming" or "same-dir", State.ghosts,
    left > 0 and string.format("%.1fs left", left) or "track clear"))
  stat_line(16, string.format("lap %d/%d %.1fs   hits %d   combo x%d   run %.1fs",
    State.lap, RACE_LAPS, State.lap_t, State.hits, State.combo, State.race_t))
  -- $/sec is what rank is made of, so this is the direct read on whether ghost
  -- count works as the reward dial.
  stat_line(28, string.format("$%.0f   $/sec %.1f   rank %s", State.cash, rate,
    track_data.rank_for_rate(State.track, rate)), gfx.COLOR_GREEN)
  if last then
    stat_line(40, string.format("last lap  %.1fs  %d hits  $/sec %.1f  rank %s",
        last.t, last.hits, last.rate, track_data.rank_for_rate(State.track, last.rate)),
      gfx.COLOR_LIGHT_GRAY)
  elseif not State.line then
    stat_line(40, "no reference line for this track", gfx.COLOR_RED)
  end
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
      6, y + (i - 1) * 12, sel and gfx.COLOR_YELLOW or gfx.COLOR_LIGHT_GRAY)
  end
end

function _draw()
  gfx.shader_uniform("u_time", usagi.elapsed)
  gfx.shader_uniform("u_resolution", { usagi.GAME_W, usagi.GAME_H })

  local t = tdata()
  -- The reverse palette, the one REVERSE_MODE swaps to: this is a reverse
  -- track, so it should read as one before the car has moved.
  road.set_palette(true)
  road.draw_track(t.map)

  local cps = t.checkpoints
  for i, cp in ipairs(cps) do
    road.draw_checkpoint(cp, i, i ~= State.next_cp, #cps)
  end

  car.draw_skid_marks(State.car)
  draw_race_line()
  draw_ghosts()
  -- Under the car and over the line: a blocked gate is a wall the car is about
  -- to hit, so it has to be the brightest thing on that stretch of road.
  if t.gates then gates.draw(t.gates, State.car) end
  car.draw_headlights(State.car)
  car.draw_taillights(State.car)
  car.draw_boosts(State.car)
  car.draw_flames(State.car)
  car.draw(State.car)
  popups.draw()

  draw_stats()
  draw_knobs()
  gfx.text("R restart  1-4/T track  G traffic  [ ] ghosts  P promote  L reload  N/B knob  , . nudge  0 defaults",
    6, usagi.GAME_H - 12, gfx.COLOR_DARK_GRAY)

  -- Over the readouts: the knobs stay legible during the count, but the number
  -- is the thing being waited on.
  if State.phase == "countdown" then
    draw_countdown()
  elseif State.phase == "finished" then
    draw_finish()
  end
end
