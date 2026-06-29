local angle      = require "angle"
local track_data = require "track_data"

local CAR_SIZE    = 16
local GHOST_ALPHA = 0.6
local LAP_PAUSE   = 0.6

local M = {}

M.LAP_PAUSE = LAP_PAUSE

local sim_time      = 0
local track_sim     = {}
local run_samples   = {}
local pending_events = {}

local function get_track_sim(id)
  if not track_sim[id] then
    track_sim[id] = { ghost_prev_phase = {}, ghost_cp_crossings = nil, ghost_coin_pickups = nil }
  end
  return track_sim[id]
end

M.get_track_sim = get_track_sim

local function compute_cp_crossings(line, checkpoints)
  if not line or #line == 0 then return nil end
  local crossings = {}
  for ci, cp in ipairs(checkpoints) do
    local rect       = track_data.checkpoint_rect(cp)
    local car_box    = { x = line[1].x, y = line[1].y, w = CAR_SIZE, h = CAR_SIZE }
    local inside_prev = util.rect_overlap(car_box, rect)
    for _, s in ipairs(line) do
      local inside = util.rect_overlap({ x = s.x, y = s.y, w = CAR_SIZE, h = CAR_SIZE }, rect)
      if inside and not inside_prev then
        crossings[ci] = { t = s.t, x = s.x + CAR_SIZE / 2, y = s.y }
        break
      end
      inside_prev = inside
    end
    if not crossings[ci] then
      crossings[ci] = { t = 0, x = rect.x + rect.w / 2, y = rect.y + rect.h / 2 }
    end
  end
  return crossings
end

local function compute_coin_pickups(line, coins, coin_count)
  if not line or #line == 0 then return nil end
  local pickups    = {}
  local ts         = track_data.tile_size
  for ci = 1, coin_count do
    local rect       = track_data.coin_rect(coins[ci])
    local car_box    = { x = line[1].x, y = line[1].y, w = CAR_SIZE, h = CAR_SIZE }
    local inside_prev = util.rect_overlap(car_box, rect)
    for _, s in ipairs(line) do
      local inside = util.rect_overlap({ x = s.x, y = s.y, w = CAR_SIZE, h = CAR_SIZE }, rect)
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
  ts.ghost_coin_pickups = compute_coin_pickups(tstate.ghost_line, tdata.coins, tstate.coins)
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
    local a    = line[i]
    local b    = line[i + 1]
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
  sim_time = sim_time + dt
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
            local phase  = (sim_time + offset) % period
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
  local events  = pending_events
  pending_events = {}
  return events
end

-- Recording for the current race run.
function M.reset_recording()
  run_samples = {}
end

function M.record(t, pose)
  run_samples[#run_samples + 1] = {
    t     = t,
    x     = pose.x,
    y     = pose.y,
    angle = pose.angle,
    drift = pose.drift,
  }
end

function M.get_recording()
  return run_samples
end

function M.promote()
  local id                    = State.active_track
  State.tracks[id].ghost_line = run_samples
  State.tracks[id].best_time  = State.race.run_time
  M.rebuild_sim(id)
end

-- Drawing.
function M.draw_sim(alpha)
  local id     = State.active_track
  local tstate = State.tracks[id]
  if not tstate then return end
  local count  = tstate.ghosts
  local line   = tstate.ghost_line
  if count <= 0 or not line then return end
  local period = M.loop_period(line)
  if period <= 0 then return end
  for i = 1, count do
    local offset = (i - 1) / count * period
    local t      = (sim_time + offset) % period
    local g      = M.sample_at(line, t)
    if g then
      gfx.spr_ex(2, g.x, g.y, false, false, g.angle - math.pi / 2, gfx.COLOR_WHITE, alpha)
    end
  end
end

function M.draw_race_ghost()
  local id     = State.active_track
  local tstate = State.tracks[id]
  if tstate.ghosts <= 0 then return end
  local g = M.sample_at(tstate.ghost_line, State.race.time)
  if g then
    gfx.spr_ex(2, g.x, g.y, false, false, g.angle - math.pi / 2, gfx.COLOR_WHITE, GHOST_ALPHA)
  end
end

return M
