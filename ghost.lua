local angle          = require "angle"
local track_data     = require "track_data"

local CAR_SIZE       = 16
local GHOST_ALPHA    = 0.2
local LAP_PAUSE      = 0.6
-- Dev tuning knob for the future "ghost tempo" upgrade: scales how fast sim
-- ghosts replay their lap (and therefore how fast they bank money). Edit and
-- hot-reload to try values; 1.0 is the real economy. Race ghosts unaffected.
local SPEED_MULT     = 1.0

local M              = {}

M.LAP_PAUSE          = LAP_PAUSE
M.SPEED_MULT         = SPEED_MULT

local sim_time       = 0
local track_sim      = {}
local pending_events = {}

local function get_track_sim(id)
  if not track_sim[id] then
    track_sim[id] = { ghost_prev_phase = {}, ghost_cp_crossings = nil, ghost_coin_pickups = nil, ghost_base = 0 }
  end
  return track_sim[id]
end

M.get_track_sim = get_track_sim

-- Re-anchor a track's ghost schedule so phase 0 lines up with right now.
-- Used when the first ghost is bought so it starts at the beginning of the line.
function M.restart_schedule(id)
  local ts            = get_track_sim(id)
  ts.ghost_base       = sim_time
  ts.ghost_prev_phase = {}
end

-- Checkpoints only count in order (like the live race): a sample overlapping
-- checkpoint N's rect is ignored unless N is the next one expected. Over `laps`
-- laps the course repeats, so the expected index wraps -- crossing 2N is
-- checkpoint N of lap 2, and carries that lap's payout multiplier.
--
-- The wrap is safe on every lap track: cp_N and cp_1 are far apart (track 2:
-- cols 32-33 to cols 1-4; track 4: center to top-right), so the seam can never
-- double-trigger off one sample.
local function compute_cp_crossings(line, checkpoints, laps)
  if not line or #line == 0 then return nil end
  local n         = #checkpoints
  local total     = (laps or 1) * n
  local crossings = {}
  local next_cp   = 1
  for _, s in ipairs(line) do
    if next_cp > total then break end
    local cp   = checkpoints[((next_cp - 1) % n) + 1]
    local rect = track_data.checkpoint_rect(cp)
    if util.rect_overlap({ x = s.x, y = s.y, w = CAR_SIZE, h = CAR_SIZE }, rect) then
      crossings[next_cp] = {
        t    = s.t,
        x    = s.x + CAR_SIZE / 2,
        y    = s.y,
        mult = track_data.lap_mult(math.floor((next_cp - 1) / n) + 1),
      }
      next_cp = next_cp + 1
    end
  end
  return crossings
end

M.compute_cp_crossings = compute_cp_crossings

-- Pay units a list of crossing/pickup events is worth: each event's multiplier
-- summed, rather than a plain count. economy.bank pays `track_pay * ev.mult`
-- per event, so anything that quotes a rate has to sum the same weights or a
-- lap track's income reads low.
local function pay_units(events)
  local units = 0
  for _, ev in ipairs(events or {}) do units = units + (ev.mult or 1) end
  return units
end

M.pay_units = pay_units

-- Pay units the stored line banks per ghost lap - every crossing and pickup it
-- genuinely makes, weighted. Builds the sim if needed.
function M.banked_pay_units(id)
  local ts = get_track_sim(id)
  if not ts.ghost_cp_crossings then M.rebuild_sim(id) end
  return pay_units(ts.ghost_cp_crossings) + pay_units(ts.ghost_coin_pickups)
end

-- Whether a sample point `s` (the car's top-left corner) overlaps a coin's
-- rect. With no magnet radius this is the car's 16px box against the coin
-- tile; with a radius, a circle centered on the car against the tile.
local function sample_overlaps(s, rect, radius)
  if radius then
    return util.circ_rect_overlap({ x = s.x + CAR_SIZE / 2, y = s.y + CAR_SIZE / 2, r = radius }, rect)
  end
  return util.rect_overlap({ x = s.x, y = s.y, w = CAR_SIZE, h = CAR_SIZE }, rect)
end

-- `coin_count` is this list's own unlock count (gold and magenta are sold and
-- clamped independently), clamped to this list's own length. `mult` rides each
-- event: it's list-attached, so a gold coin pays 1x even when swept up on lap
-- 2 (see track_data's LAP_COIN_MULT).
--
-- `from_t` is when the list goes live (nil for the gold list, lap 2's start
-- for the magenta one): samples before it are skipped entirely, because the
-- live race can't collect out of a list its lap hasn't opened yet. Without it a
-- ghost banks magenta coins its lap-1 pass swept -- coins the player drove
-- straight through for nothing -- and the track's income overstates the lap
-- that earned it. At a window that opens mid-drive there's no earlier frame to
-- take an edge off, and the live race collects on any overlapping frame (no
-- rising edge there at all), so an overlap on the first sample counts.
local function compute_coin_pickups(line, coins, coin_count, radius, mult, from_t)
  if not line or #line == 0 then return nil end
  local pickups = {}
  local ts      = track_data.tile_size
  for ci = 1, math.min(coin_count, #coins) do
    local rect        = track_data.coin_rect(coins[ci])
    -- A window that opens mid-drive has no earlier frame to edge off, so it
    -- starts "outside" and an overlap on its first sample counts. The whole-line
    -- window instead seeds from its own first sample, so a coin the car is sat
    -- on at the grid still needs a rising edge. (Not `from_t and false or nil`:
    -- `false or nil` is nil.)
    local inside_prev = nil
    if from_t then inside_prev = false end
    for _, s in ipairs(line) do
      if not from_t or s.t >= from_t then
        local inside = sample_overlaps(s, rect, radius)
        if inside_prev == nil then inside_prev = inside end
        if inside and not inside_prev then
          pickups[#pickups + 1] = { t = s.t, x = rect.x + ts / 2, y = rect.y, mult = mult or 1 }
          break
        end
        inside_prev = inside
      end
    end
  end
  return pickups
end

M.compute_coin_pickups = compute_coin_pickups

-- When the stored line opens lap 2: its crossing of the last checkpoint of lap
-- 1, which is exactly the rollover the live race gates the magenta list behind
-- (scenes/race's begin_next_lap). nil when the line never completed a lap 1's
-- worth of checkpoints - a single-lap recording still sitting on a track whose
-- Extra Lap was bought afterwards - and the magenta list then contributes
-- nothing, which is the truth: that lap was never driven.
function M.lap2_start(crossings, cp_count)
  local ev = crossings and crossings[cp_count]
  return ev and ev.t
end

-- Pickups across both of a track's coin lists, merged into one event list. The
-- lap-2 list only exists on a lap track and only when laps are switched on, and
-- only counts from lap 2's start (see compute_coin_pickups' `from_t`), so
-- `crossings` -- the same list compute_cp_crossings built for this line -- has
-- to come in with it. `coin_count` and `coin2_count` are each list's own
-- independent unlock count.
function M.compute_all_coin_pickups(line, tdata, coin_count, coin2_count, radius, laps, crossings)
  local pickups = compute_coin_pickups(line, tdata.coins, coin_count, radius, 1)
  if not pickups then return nil end
  if laps > 1 and tdata.coins2 then
    local from_t = M.lap2_start(crossings, #tdata.checkpoints)
    if from_t then
      local lap2 = compute_coin_pickups(line, tdata.coins2, coin2_count, radius,
        track_data.LAP_COIN_MULT, from_t)
      for _, ev in ipairs(lap2 or {}) do pickups[#pickups + 1] = ev end
    end
  end
  return pickups
end

-- ghost.promote stores the whole multi-lap recording, so loop_period is already
-- the multi-lap time. Both event sets have to cover the same span or the
-- track's income would be lap-1 pay divided by lap-2 time - a silent halving of
-- the entire idle economy, buried inside a laps experiment.
function M.rebuild_sim(id)
  local ts              = get_track_sim(id)
  local tstate          = State.tracks[id]
  local tdata           = track_data.TRACKS[id]
  local laps            = track_data.effective_laps(id)
  ts.ghost_cp_crossings = compute_cp_crossings(tstate.ghost_line, tdata.checkpoints, laps)
  ts.ghost_coin_pickups = M.compute_all_coin_pickups(tstate.ghost_line, tdata, tstate.coins, tstate.coins2,
    track_data.magnet_radius(State.magnet), laps, ts.ghost_cp_crossings)
  ts.ghost_prev_phase   = {}
end

function M.reset_track_phases(id)
  get_track_sim(id).ghost_prev_phase = {}
end

function M.reset_all_phases()
  for id, v in pairs(State.unlocked) do
    if v then get_track_sim(id).ghost_prev_phase = {} end
  end
end

-- Drops every cached track sim and any queued crossing events. Used when the
-- whole progression state is replaced (start of a new loop).
function M.clear_all_sims()
  track_sim      = {}
  pending_events = {}
end

function M.loop_period(line)
  if not line or #line == 0 then return 0 end
  return line[#line].t + LAP_PAUSE
end

function M.sample_at(line, time)
  if not line or #line == 0 then return nil end
  if time <= line[1].t then return line[1] end
  local last = line[#line]
  if time >= last.t then return last end
  for i = 1, #line - 1 do
    local a = line[i]
    local b = line[i + 1]
    if time >= a.t and time <= b.t then
      local span = b.t - a.t
      local t    = span > 0 and (time - a.t) / span or 0
      return {
        x     = util.lerp(a.x, b.x, t),
        y     = util.lerp(a.y, b.y, t),
        angle = angle.lerp(a.angle, b.angle, t),
        drift = a.drift,
      }
    end
  end
  return last
end

-- The same left-right flip track_data.mirror_track applies to a track's
-- geometry, applied to a recorded line so a ghost can run the mirrored layout.
-- Positions are the car's top-left corner, so the x flip has to subtract the
-- car's own footprint as well -- without it every sample sits one car-width
-- into the wall on the far side.
function M.mirror_line(line, map_w_px)
  if not line then return nil end
  local out = {}
  for i, s in ipairs(line) do
    out[i] = {
      t     = s.t,
      x     = map_w_px - CAR_SIZE - s.x,
      y     = s.y,
      angle = angle.normalize(math.pi - s.angle),
      drift = s.drift,
    }
  end
  return out
end

-- A playable ghost line built from a track's stored reference lap
-- (data/ref_<id>.json), for callers with no save and therefore no
-- tstate.ghost_line. The reference holds only {t, x, y}, so headings are
-- derived from each point's delta to the next -- good enough to point a sprite
-- the right way, which is all a ghost's angle is ever used for. Returns nil
-- when the track has no reference recorded.
--
-- `reference` is required lazily: it requires this module at load, so a
-- top-level require here would be a cycle.
function M.line_from_reference(id)
  local reference = require "reference"
  local data      = reference.load(id)
  local pts       = data and data.points
  if not pts or #pts == 0 then return nil end
  local line = {}
  local prev = 0
  for i, p in ipairs(pts) do
    local nxt = pts[i + 1]
    local a   = prev
    if nxt then
      local dx, dy = nxt.x - p.x, nxt.y - p.y
      -- A pair of coincident points (the car stopped) carries the last real
      -- heading forward rather than snapping the sprite to east.
      if dx * dx + dy * dy > 0 then a = math.atan(dy, dx) end
    end
    line[i] = { t = p.t, x = p.x, y = p.y, angle = a, drift = false }
    prev    = a
  end
  return line
end

-- Advance sim_time and detect ghost crossings for all unlocked tracks.
-- Results are queued; call collect_crossings() to drain them.
function M.update(dt)
  sim_time = sim_time + dt * SPEED_MULT
  for _, id in ipairs(track_data.TRACK_ORDER) do
    if State.unlocked[id] and State.tracks[id] then
      local tstate = State.tracks[id]
      local count  = tstate.ghosts
      local line   = tstate.ghost_line
      if count > 0 and line then
        local ts = get_track_sim(id)
        if not ts.ghost_cp_crossings then M.rebuild_sim(id) end
        local period = M.loop_period(line)
        if ts.ghost_cp_crossings and period > 0 then
          for i = 1, count do
            local offset = (i - 1) / count * period
            local phase  = (sim_time - ts.ghost_base + offset) % period
            local prev   = ts.ghost_prev_phase[i]
            if prev then
              for _, ev in ipairs(ts.ghost_cp_crossings) do
                local crossed
                if phase >= prev then
                  crossed = ev.t > prev and ev.t <= phase
                else
                  crossed = ev.t > prev or ev.t <= phase
                end
                if crossed then
                  pending_events[#pending_events + 1] = {
                    kind     = "checkpoint",
                    track_id = id,
                    x        = ev.x,
                    y        = ev.y,
                    mult     = ev.mult,
                  }
                end
              end
              if ts.ghost_coin_pickups then
                for _, ev in ipairs(ts.ghost_coin_pickups) do
                  local crossed
                  if phase >= prev then
                    crossed = ev.t > prev and ev.t <= phase
                  else
                    crossed = ev.t > prev or ev.t <= phase
                  end
                  if crossed then
                    pending_events[#pending_events + 1] = {
                      kind     = "coin",
                      track_id = id,
                      x        = ev.x,
                      y        = ev.y,
                      mult     = ev.mult,
                    }
                  end
                end
              end
            end
            ts.ghost_prev_phase[i] = phase
          end
        end
      end
    end
  end
end

function M.collect_crossings()
  local events   = pending_events
  pending_events = {}
  return events
end

-- Recording for the current race run. Stored on State (not a file-scope
-- local) so a mid-race dev live-reload doesn't wipe the in-progress lap.
function M.reset_recording()
  State.race.recording = {}
end

function M.record(t, pose)
  local run_samples             = State.race.recording
  run_samples[#run_samples + 1] = {
    t     = t,
    x     = pose.x,
    y     = pose.y,
    angle = pose.angle,
    drift = pose.drift,
  }
end

function M.get_recording()
  return State.race.recording
end

-- Stores the finished run as the track's ghost lap, but only if it beats the
-- stored best $/sec - a worse lap leaves the ghost (and therefore the rank)
-- untouched. Returns true when the lap was promoted.
function M.promote()
  local id     = State.active_track
  local tstate = State.tracks[id]
  if tstate.best_rate and State.race.run_rate <= tstate.best_rate then
    return false
  end
  tstate.ghost_line = State.race.recording
  tstate.best_rate  = State.race.run_rate
  M.rebuild_sim(id)
  return true
end

-- Drawing.
function M.draw_sim(alpha)
  local id     = State.active_track
  local tstate = State.tracks[id]
  if not tstate then return end
  local count = tstate.ghosts
  local line  = tstate.ghost_line
  if count <= 0 or not line then return end
  local period = M.loop_period(line)
  if period <= 0 then return end
  local ts = get_track_sim(id)
  for i = 1, count do
    local offset = (i - 1) / count * period
    local t      = (sim_time - ts.ghost_base + offset) % period
    local g      = M.sample_at(line, t)
    if g then
      gfx.spr_ex(2, g.x, g.y, false, false, g.angle - math.pi / 2, gfx.COLOR_WHITE, alpha)
    end
  end
end

function M.draw_race_ghost()
  local id     = State.active_track
  local tstate = State.tracks[id]
  if not tstate.ghost_line then return end
  local g = M.sample_at(tstate.ghost_line, State.race.time)
  if g then
    gfx.spr_ex(2, g.x, g.y, false, false, g.angle - math.pi / 2, gfx.COLOR_WHITE, GHOST_ALPHA)
  end
end

return M
