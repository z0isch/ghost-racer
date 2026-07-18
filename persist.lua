local track_data = require "track_data"
local car        = require "car"
local ghost      = require "ghost"
local skill_tree = require "skill_tree"

local M          = {}

-- ¥ granted for completing a loop, paid into the skill tree by
-- start_new_loop. Exposed so the Loop Complete modal copy can't drift.
M.LOOP_REWARD    = 100

local function default_state()
  return {
    mode               = "buy",
    money              = 10000000,
    seen_help          = false,
    loop               = 1,
    loop_time          = 0,
    seen_modals        = {},
    accel              = 0,
    top_speed          = 0,
    start_coins        = 0,
    unlock_checkpoints = false,
    skill_tree         = skill_tree.new(),
    drift              = 0,
    drift_boost        = 0,
    boost              = 0,
    nirvana            = 0,
    magnet             = 0,
    active_track       = "track1",
    unlocked           = { track1 = true },
    tracks             = { track1 = track_data.default_track_state("track1", 1) },
    car                = car.default_state(),
    race               = {
      next_checkpoint = 1,
      time            = 0,
      phase           = "countdown",
      coins_collected = {},
    },
  }
end

-- Dev-only snapshot file, written/read next to `main.lua` so `usagi.read_json`
-- (which resolves paths under `data/`) can load it back in.
local DEV_SNAPSHOT_REL  = "dev_snapshot.json"
local DEV_SNAPSHOT_FILE = "data/" .. DEV_SNAPSHOT_REL

-- Fields carried by both the real save file and dev snapshots.
local function progression_of_state()
  return {
    money        = State.money,
    seen_help    = State.seen_help,
    loop         = State.loop,
    loop_time    = State.loop_time,
    seen_modals  = State.seen_modals,
    accel        = State.accel,
    -- top_speed / start_coins / unlock_checkpoints are derived caches of the
    -- skill tree, not saved; the tree is the single source of truth. fx is
    -- transient render state, also dropped.
    skill_tree   = { points = State.skill_tree.points, ranks = State.skill_tree.ranks },
    drift        = State.drift,
    drift_boost  = State.drift_boost,
    boost        = State.boost,
    nirvana      = State.nirvana,
    magnet       = State.magnet,
    active_track = State.active_track,
    unlocked     = State.unlocked,
    tracks       = State.tracks,
  }
end

-- Applies a progression table (shape of `progression_of_state`) onto the
-- current State in place. Shared by the real load path and dev snapshot load.
local function apply_progression(loaded)
  State.money       = loaded.money or 0
  State.seen_help   = loaded.seen_help or false
  State.loop        = loaded.loop or 1
  State.loop_time   = loaded.loop_time or 0
  State.seen_modals = loaded.seen_modals or {}

  State.accel       = math.min(loaded.accel or 0, track_data.kind_max("accel") or 0)
  State.drift       = math.min(loaded.drift or 0, track_data.kind_max("drift") or 0)
  State.drift_boost = math.min(loaded.drift_boost or 0, track_data.kind_max("drift_boost") or 0)
  State.boost       = math.min(loaded.boost or 0, track_data.kind_max("boost") or 0)
  State.nirvana     = math.min(loaded.nirvana or 0, track_data.kind_max("nirvana") or 0)
  State.magnet      = math.min(loaded.magnet or 0, track_data.kind_max("magnet") or 0)

  if loaded.active_track and track_data.TRACKS[loaded.active_track] then
    State.active_track = loaded.active_track
  end

  if loaded.unlocked then
    for id, v in pairs(loaded.unlocked) do
      if track_data.TRACKS[id] then
        State.unlocked[id] = v
        if v and not State.tracks[id] then
          State.tracks[id] = track_data.default_track_state(id, State.loop)
        end
      end
    end
  end

  if loaded.tracks then
    for id, lt in pairs(loaded.tracks) do
      if track_data.TRACKS[id] then
        if not State.tracks[id] then
          State.tracks[id] = track_data.default_track_state(id, State.loop)
        end
        local ts       = State.tracks[id]
        ts.ghost_line  = lt.ghost_line
        ts.best_rate   = lt.best_rate
        ts.ghosts      = math.min(lt.ghosts or 0, track_data.kind_max("ghosts"))
        -- Only the ceiling here; the start_coins floor needs the skill tree,
        -- which loads below - rederive_skill_effects raises to it at the end.
        ts.coins       = math.min(lt.coins or 0, track_data.max_coins(id, State.loop))
        ts.checkpoints = math.max(1,
          math.min(lt.checkpoints or 1, #track_data.TRACKS[id].checkpoints))
      end
    end
  end

  -- No rank clamping: the defs' `max` only gates future buys, and the game is
  -- unreleased. fx is transient render state, always rebuilt empty.
  if loaded.skill_tree then
    State.skill_tree.points = loaded.skill_tree.points or 0
    State.skill_tree.ranks  = loaded.skill_tree.ranks or {}
  end
  State.skill_tree.fx = {}

  M.rederive_skill_effects()
end

-- State.top_speed / State.start_coins / State.unlock_checkpoints are caches
-- derived from the skill tree; the tree is the single source of truth.
-- Re-derive after any rank change or load, before resync_car_and_ghosts
-- pushes results into the car and ghost sims. The coin floor and checkpoint
-- unlock are applied live to existing tracks so a rank bought at the loop
-- gate takes effect that loop, not the next.
function M.rederive_skill_effects()
  local ctx                = skill_tree.apply_all(State.skill_tree, {})
  State.top_speed          = ctx.top_speed or 0
  State.start_coins        = ctx.start_coins or 0
  State.unlock_checkpoints = ctx.unlock_checkpoints or false
  for id, ts in pairs(State.tracks) do
    ts.coins = math.max(ts.coins,
      track_data.start_coin_floor(id, State.loop, State.start_coins))
    if State.unlock_checkpoints then
      ts.checkpoints = #track_data.TRACKS[id].checkpoints
    end
  end
end

-- Re-syncs car tuning and ghost sims after progression fields change out
-- from under them (real load at boot, or a dev snapshot restore mid-session).
function M.resync_car_and_ghosts()
  car.apply_upgrades(State.car, State.accel, State.top_speed, State.drift >= 1, State.drift_boost >= 1, State.boost)
  for id, _ in pairs(State.unlocked) do
    ghost.rebuild_sim(id)
  end
end

-- Buying Nirvana ends the game... into a new loop: everything resets to a
-- fresh save except the loop counter and dismissed tutorials. Loop 2 opens
-- up the full game (all four tracks, ghosts, coins); head-start coins come
-- from the skill tree's Head Start ranks (see track_data.start_coin_floor).
function M.start_new_loop()
  local next_loop         = (State.loop or 1) + 1
  local finished_time     = State.loop_time or 0
  local seen_help         = State.seen_help
  local seen_modals       = State.seen_modals
  local tree              = State.skill_tree
  State                   = default_state()
  State.loop              = next_loop
  State.seen_help         = seen_help
  State.seen_modals       = seen_modals
  -- Carry the skill tree across the reset (like seen_help) and pay the loop
  -- reward atomically with the rollover. fx is transient, rebuilt empty.
  State.skill_tree        = tree
  State.skill_tree.fx     = {}
  State.skill_tree.points = State.skill_tree.points + M.LOOP_REWARD
  -- Not part of default_state/progression - only read once by the "Well
  -- Done!" modal that's about to show, reporting on the loop that just ended.
  State.last_loop_time    = finished_time
  State.tracks.track1     = track_data.default_track_state("track1", next_loop)
  -- The ending modal always shows, even on repeat loops - it's the payoff,
  -- not a tutorial.
  State.purchase_modal    = "nirvana"
  ghost.clear_all_sims()
  M.rederive_skill_effects()
  M.resync_car_and_ghosts()
  M.save()
end

function M.save()
  usagi.save(progression_of_state())
end

function M.load()
  local loaded = usagi.load()
  State = default_state()
  if loaded then
    apply_progression(loaded)
  end
  State.mode = loaded and "buy" or "intro"
  -- State.mode isn't persisted, so quitting at the forced skill-tree screen
  -- would otherwise reload into buy and skip the gate. Resume the gate.
  if loaded and State.loop >= 2 and skill_tree.rank(State.skill_tree, "top_speed") == 0 then
    State.mode = "skill_tree"
  end
end

-- Dev-only: writes the current progression state as JSON to
-- data/dev_snapshot.json, so it can be reloaded with `dev_load_snapshot`
-- (or hand-edited for tuning) across restarts.
function M.dev_save_snapshot()
  local json   = usagi.to_json(progression_of_state())
  local f, err = io.open(DEV_SNAPSHOT_FILE, "w")
  if not f then
    print("[dev] failed to write " .. DEV_SNAPSHOT_FILE .. ": " .. tostring(err))
    return
  end
  f:write(json)
  f:close()
  print("[dev] state snapshot saved to " .. DEV_SNAPSHOT_FILE)
end

-- Dev-only: restores progression state from data/dev_snapshot.json onto the
-- currently running State.
function M.dev_load_snapshot()
  local ok, snap = pcall(usagi.read_json, DEV_SNAPSHOT_REL)
  if not ok or not snap then
    print("[dev] no snapshot found at " .. DEV_SNAPSHOT_FILE)
    return
  end
  apply_progression(snap)
  M.resync_car_and_ghosts()
  print("[dev] state snapshot loaded from " .. DEV_SNAPSHOT_FILE)
end

return M
