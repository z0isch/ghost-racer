local track_data = require "track_data"

local M = {}

local function default_state()
  return {
    mode         = "buy",
    money        = 100000,
    coins        = 100000,
    accel        = 0,
    top_speed    = 0,
    active_track = "basic",
    unlocked     = { basic = true },
    tracks       = { basic = track_data.default_track_state("basic") },
    race         = {
      next_checkpoint = 1,
      time            = 0,
      phase           = "countdown",
      earned          = 0,
      coins_earned    = 0,
      coins_collected = {},
    },
  }
end

function M.save()
  usagi.save({
    money        = State.money,
    coins        = State.coins,
    accel        = State.accel,
    top_speed    = State.top_speed,
    active_track = State.active_track,
    unlocked     = State.unlocked,
    tracks       = State.tracks,
  })
end

function M.load()
  local loaded = usagi.load()
  State = default_state()
  if loaded then
    State.money     = loaded.money or 0
    State.coins     = loaded.coins or 0

    State.accel     = math.min(loaded.accel, track_data.kind_max("accel"))
    State.top_speed = math.min(loaded.top_speed, track_data.kind_max("top_speed"))

    if loaded.active_track and track_data.TRACKS[loaded.active_track] then
      State.active_track = loaded.active_track
    end

    if loaded.unlocked then
      for id, v in pairs(loaded.unlocked) do
        if track_data.TRACKS[id] then
          State.unlocked[id] = v
          if v and not State.tracks[id] then
            State.tracks[id] = track_data.default_track_state(id)
          end
        end
      end
    end

    if loaded.tracks then
      for id, lt in pairs(loaded.tracks) do
        if track_data.TRACKS[id] then
          if not State.tracks[id] then
            State.tracks[id] = track_data.default_track_state(id)
          end
          local ts      = State.tracks[id]
          local tdata   = track_data.TRACKS[id]
          ts.ghost_line = lt.ghost_line
          ts.best_time  = lt.best_time
          ts.ghosts     = math.min(lt.ghosts or 0, track_data.kind_max("ghosts"))
          ts.coins      = math.min(lt.coins or 0, #tdata.coins)
        end
      end
    else
      if loaded.upgrades then
        State.tracks.basic.ghosts = math.min(loaded.upgrades.ghosts or 0, track_data.kind_max("ghosts"))
        State.tracks.basic.coins  = math.min(loaded.upgrades.coins or 0, #track_data.TRACKS.basic.coins)
      end
    end
  end
  State.mode = "buy"
end

return M
