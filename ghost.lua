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
-- checkpoint N's rect is ignored unless N is the next one expected.
local function compute_cp_crossings(line, checkpoints)
  if not line or #line == 0 then return nil end
  local crossings = {}
  local next_cp   = 1
  for _, s in ipairs(line) do
    local cp = checkpoints[next_cp]
    if not cp then break end
    local rect = track_data.checkpoint_rect(cp)
    if util.rect_overlap({ x = s.x, y = s.y, w = CAR_SIZE, h = CAR_SIZE }, rect) then
      crossings[next_cp] = { t = s.t, x = s.x + CAR_SIZE / 2, y = s.y }
      next_cp            = next_cp + 1
    end
  end
  return crossings
end

M.compute_cp_crossings = compute_cp_crossings

-- Checkpoints the stored line genuinely crosses, building the sim if needed.
function M.crossed_cp_count(id)
  local ts = get_track_sim(id)
  if not ts.ghost_cp_crossings then M.rebuild_sim(id) end
  return ts.ghost_cp_crossings and #ts.ghost_cp_crossings or 0
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

local function compute_coin_pickups(line, coins, coin_count, radius)
  if not line or #line == 0 then return nil end
  local pickups = {}
  local ts      = track_data.tile_size
  for ci = 1, coin_count do
    local rect        = track_data.coin_rect(coins[ci])
    local inside_prev = sample_overlaps(line[1], rect, radius)
    for _, s in ipairs(line) do
      local inside = sample_overlaps(s, rect, radius)
      if inside and not inside_prev then
        pickups[#pickups + 1] = { t = s.t, x = rect.x + ts / 2, y = rect.y }
        break
      end
      inside_prev = inside
    end
  end
  return pickups
end

M.compute_coin_pickups = compute_coin_pickups

function M.rebuild_sim(id)
  local ts              = get_track_sim(id)
  local tstate          = State.tracks[id]
  local tdata           = track_data.TRACKS[id]
  ts.ghost_cp_crossings = compute_cp_crossings(tstate.ghost_line, tdata.checkpoints)
  ts.ghost_coin_pickups = compute_coin_pickups(tstate.ghost_line, tdata.coins, tstate.coins,
    track_data.magnet_radius(State.magnet))
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
