local track_data = require "track_data"

local M = {}

local function default_state()
  return {
    mode         = "buy",
    money        = 10000,
    seen_help    = false,
    accel        = 0,
    top_speed    = 0,
    drift        = 0,
    drift_boost  = 0,
    boost        = 0,
    active_track = "track1",
    unlocked     = { track1 = true },
    tracks       = { track1 = track_data.default_track_state() },
    race         = {
      next_checkpoint = 1,
      time            = 0,
      phase           = "countdown",
      earned          = 0,
      coins_collected = {},
    },
  }
end

function M.save()
  usagi.save({
    money        = State.money,
    seen_help    = State.seen_help,
    accel        = State.accel,
    top_speed    = State.top_speed,
    drift        = State.drift,
    drift_boost  = State.drift_boost,
    boost        = State.boost,
    active_track = State.active_track,
    unlocked     = State.unlocked,
    tracks       = State.tracks,
  })
end

function M.load()
  local loaded = usagi.load()
  State = default_state()
  if loaded then
    State.money       = loaded.money or 0
    State.seen_help   = loaded.seen_help or false

    State.accel       = math.min(loaded.accel or 0, track_data.kind_max("accel") or 0)
    State.top_speed   = math.min(loaded.top_speed or 0, track_data.kind_max("top_speed") or 0)
    State.drift       = math.min(loaded.drift or 0, track_data.kind_max("drift") or 0)
    State.drift_boost = math.min(loaded.drift_boost or 0, track_data.kind_max("drift_boost") or 0)
    State.boost       = math.min(loaded.boost or 0, track_data.kind_max("boost") or 0)

    if loaded.active_track and track_data.TRACKS[loaded.active_track] then
      State.active_track = loaded.active_track
    end

    if loaded.unlocked then
      for id, v in pairs(loaded.unlocked) do
        if track_data.TRACKS[id] then
          State.unlocked[id] = v
          if v and not State.tracks[id] then
            State.tracks[id] = track_data.default_track_state()
          end
        end
      end
    end

    if loaded.tracks then
      for id, lt in pairs(loaded.tracks) do
        if track_data.TRACKS[id] then
          if not State.tracks[id] then
            State.tracks[id] = track_data.default_track_state()
          end
          local ts         = State.tracks[id]
          local tdata      = track_data.TRACKS[id]
          ts.ghost_line    = lt.ghost_line
          ts.best_time     = lt.best_time
          ts.best_earned   = lt.best_earned
          ts.cash_per_sec  = lt.cash_per_sec
          ts.ghosts        = math.min(lt.ghosts or 0, track_data.kind_max("ghosts"))
          ts.coins         = math.min(lt.coins or 0, #tdata.coins)
          ts.a_rank_earned = lt.a_rank_earned or false
        end
      end
    else
      if loaded.upgrades then
        State.tracks.basic.ghosts = math.min(loaded.upgrades.ghosts or 0, track_data.kind_max("ghosts"))
        State.tracks.basic.coins  = math.min(loaded.upgrades.coins or 0, #track_data.TRACKS.basic.coins)
      end
    end
  end
  State.mode = loaded and "buy" or "intro"
end

return M
