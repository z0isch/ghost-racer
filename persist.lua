local track_data          = require "track_data"
local car                 = require "car"
local ghost               = require "ghost"
local skill_tree          = require "skill_tree"

local M                   = {}

-- ¥ granted for finishing the loop-1 prologue, paid into the skill tree by
-- start_new_loop. Flat, because the prologue is authored and its rank isn't
-- a fair measure of anything yet. Exposed so the garage's first-visit copy
-- ("Here's ¥N to start!") can't drift from what was actually paid.
M.LOOP_REWARD             = 100

-- ¥ paid for completing a loop 2+, by the rank that loop earned. This is what
-- rank is *for* now that track purchases are gated on cash alone: rank is
-- already the in-loop cash multiplier (see economy.pay_for_mult), and this
-- makes it the cross-loop one too. B holds at the old flat 100 so skill-tree
-- pacing keeps its baseline; a bad loop still pays, and a great loop is worth
-- 5x a bad one. Moderate rather than punitive on purpose - a loop can't be
-- finished at all without earning enough to buy all four tracks, so there's
-- no cheap loop to farm. Tuning knobs only - change freely.
local LOOP_REWARD_BY_RANK = { D = 40, C = 70, B = 100, A = 140, S = 200 }

function M.loop_reward(rank)
  return LOOP_REWARD_BY_RANK[rank] or M.LOOP_REWARD
end

local function default_state()
  return {
    mode               = "buy",
    money              = 0,
    seen_help          = false,
    loop               = 1,
    loop_time          = 0,
    seen_modals        = {},
    -- Track ids whose "Track #N available in the shop!" announcement has
    -- already fired this loop, so it lands once on the race that made the
    -- track affordable instead of every time the balance re-crosses the
    -- price. Per-loop: start_new_loop resets it with the rest of the state.
    announced_unlock   = {},
    -- Same idea for the "Nirvana available!" announcement, which now fires on
    -- affording the exit rather than on revealing it. Per-loop, one field
    -- rather than a set: only one track sells Nirvana in a loop.
    announced_nirvana  = false,
    accel              = 0,
    top_speed          = 0,
    start_coins        = 0,
    coins_unlocked     = false,
    unlock_checkpoints = false,
    max_accel          = false,
    skill_tree         = skill_tree.new(),
    drift              = 0,
    drift_boost        = 0,
    boost              = 0,
    nirvana            = 0,
    magnet             = 0,
    active_track       = "track1",
    unlocked           = { track1 = true },
    tracks             = { track1 = track_data.default_track_state("track1", false) },
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
    money             = State.money,
    seen_help         = State.seen_help,
    loop              = State.loop,
    loop_time         = State.loop_time,
    seen_modals       = State.seen_modals,
    announced_unlock  = State.announced_unlock,
    announced_nirvana = State.announced_nirvana,
    accel             = State.accel,
    -- top_speed / start_coins / coins_unlocked / unlock_checkpoints /
    -- max_accel are derived caches of the skill tree, not saved; the tree is
    -- the single source of truth. fx is transient render state, also dropped.
    -- (accel itself is race-shop progression and is saved, but Launch Control
    -- floors it at max on every rederive.)
    skill_tree        = {
      points    = State.skill_tree.points,
      ranks     = State.skill_tree.ranks,
      bought_at = State.skill_tree.bought_at,
    },
    drift             = State.drift,
    drift_boost       = State.drift_boost,
    boost             = State.boost,
    nirvana           = State.nirvana,
    magnet            = State.magnet,
    active_track      = State.active_track,
    unlocked          = State.unlocked,
    tracks            = State.tracks,
  }
end

-- Applies a progression table (shape of `progression_of_state`) onto the
-- current State in place. Shared by the real load path and dev snapshot load.
local function apply_progression(loaded)
  State.money             = loaded.money or 0
  State.seen_help         = loaded.seen_help or false
  State.loop              = loaded.loop or 1
  State.loop_time         = loaded.loop_time or 0
  State.seen_modals       = loaded.seen_modals or {}
  State.announced_unlock  = loaded.announced_unlock or {}
  State.announced_nirvana = loaded.announced_nirvana or false

  State.accel             = math.min(loaded.accel or 0, track_data.kind_max("accel") or 0)
  State.drift             = math.min(loaded.drift or 0, track_data.kind_max("drift") or 0)
  State.drift_boost       = math.min(loaded.drift_boost or 0, track_data.kind_max("drift_boost") or 0)
  State.boost             = math.min(loaded.boost or 0, track_data.kind_max("boost") or 0)
  State.nirvana           = math.min(loaded.nirvana or 0, track_data.kind_max("nirvana") or 0)
  State.magnet            = math.min(loaded.magnet or 0, track_data.kind_max("magnet") or 0)

  if loaded.active_track and track_data.TRACKS[loaded.active_track] then
    State.active_track = loaded.active_track
  end

  if loaded.unlocked then
    for id, v in pairs(loaded.unlocked) do
      if track_data.TRACKS[id] then
        State.unlocked[id] = v
        if v and not State.tracks[id] then
          State.tracks[id] = track_data.default_track_state(id, State.coins_unlocked)
        end
      end
    end
  end

  if loaded.tracks then
    for id, lt in pairs(loaded.tracks) do
      if track_data.TRACKS[id] then
        if not State.tracks[id] then
          State.tracks[id] = track_data.default_track_state(id, State.coins_unlocked)
        end
        local ts       = State.tracks[id]
        ts.ghost_line  = lt.ghost_line
        ts.best_rate   = lt.best_rate
        ts.ghosts      = math.min(lt.ghosts or 0, track_data.kind_max("ghosts"))
        -- Raw here; both the coin ceiling and the start_coins floor need the
        -- skill tree, which loads below - rederive_skill_effects clamps at the
        -- end.
        ts.coins       = lt.coins or 0
        ts.checkpoints = math.max(1,
          math.min(lt.checkpoints or 1, #track_data.TRACKS[id].checkpoints))
      end
    end
  end

  -- No rank clamping: the defs' `max` only gates future buys, and the game is
  -- unreleased. fx is transient render state, always rebuilt empty.
  if loaded.skill_tree then
    State.skill_tree.points    = loaded.skill_tree.points or 0
    State.skill_tree.ranks     = loaded.skill_tree.ranks or {}
    State.skill_tree.bought_at = loaded.skill_tree.bought_at or {}
  end
  State.skill_tree.fx = {}

  M.rederive_skill_effects()
end

-- State.top_speed / State.start_coins / State.coins_unlocked /
-- State.unlock_checkpoints / State.max_accel are caches derived from the skill
-- tree; the tree is the single source of truth. Re-derive after any rank change
-- or load, before resync_car_and_ghosts pushes results into the car and ghost
-- sims. The coin ceiling/floor and the checkpoint unlock are applied live to
-- existing tracks so a rank bought at the loop gate takes effect that loop, not
-- the next.
function M.rederive_skill_effects()
  local ctx                = skill_tree.apply_all(State.skill_tree, {})
  State.top_speed          = ctx.top_speed or 0
  State.start_coins        = ctx.start_coins or 0
  State.coins_unlocked     = ctx.coins or false
  State.unlock_checkpoints = ctx.unlock_checkpoints or false
  State.max_accel          = ctx.max_accel or false
  -- Launch Control floors accel at max rather than replacing it, so a save
  -- that already bought ranks the hard way reads back unchanged. The shop row
  -- hides itself once this is on (see scenes/buy.lua).
  if State.max_accel then
    State.accel = math.max(State.accel, track_data.kind_max("accel") or 0)
  end
  for id, ts in pairs(State.tracks) do
    -- Ceiling before floor: without Loose Change the ceiling is 0, which is
    -- also where the floor lands, so a coinless save reads back coinless.
    ts.coins = math.min(ts.coins, track_data.max_coins(id, State.coins_unlocked))
    ts.coins = math.max(ts.coins,
      track_data.start_coin_floor(id, State.coins_unlocked, State.start_coins))
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
-- up the full game (all four tracks, ghosts); coins arrive later still, with
-- the skill tree's Loose Change node, and head-start coins with Head Start
-- above it (see track_data.start_coin_floor).
function M.start_new_loop()
  local old_loop            = State.loop or 1
  local next_loop           = old_loop + 1
  local finished_time       = State.loop_time or 0
  -- Score the finished loop before the reset wipes State.tracks: the per-course
  -- ranks, the loop_points they earn at this time, and the letter that lands
  -- on. All read once by the loop-rank breakdown modal (see scenes/buy.lua).
  local had_coins           = State.coins_unlocked
  local finished_courses    = track_data.loop_course_ranks(old_loop, State.tracks, had_coins)
  local finished_points     = track_data.loop_points(old_loop, State.tracks, finished_time, had_coins)
  local finished_rank       = track_data.loop_rank_for_points(finished_points)
  local seen_help           = State.seen_help
  local seen_modals         = State.seen_modals
  local tree                = State.skill_tree
  State                     = default_state()
  State.loop                = next_loop
  State.seen_help           = seen_help
  State.seen_modals         = seen_modals
  -- Carry the skill tree across the reset (like seen_help) and pay the loop
  -- reward atomically with the rollover. The prologue pays its flat stipend;
  -- every loop after that pays by the rank it just earned. fx is transient,
  -- rebuilt empty.
  local reward              = old_loop == 1 and M.LOOP_REWARD or M.loop_reward(finished_rank)
  State.skill_tree          = tree
  State.skill_tree.fx       = {}
  State.skill_tree.points   = State.skill_tree.points + reward
  -- Not part of default_state/progression - only read once by the "Well
  -- Done!" modal that's about to show, reporting on the loop that just ended.
  State.last_loop_time      = finished_time
  State.last_loop_rank      = finished_rank
  State.last_loop_breakdown = {
    courses = finished_courses,
    time    = finished_time,
    points  = finished_points,
    rank    = finished_rank,
  }
  -- The tree survives the reset, so coin availability does too; the coin floor
  -- itself is applied by the rederive below.
  State.tracks.track1       = track_data.default_track_state("track1", had_coins)
  -- The ending modal always shows, even on repeat loops - it's the payoff,
  -- not a tutorial.
  State.purchase_modal      = "nirvana"
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
