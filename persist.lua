local track_data = require "track_data"
local car        = require "car"
local ghost      = require "ghost"
local skill_tree = require "skill_tree"

local M          = {}

local function default_state()
  return {
    mode             = "buy",
    money            = 0,
    seen_help        = false,
    loop             = 1,
    loop_time_left   = track_data.LOOP_SECONDS,
    seen_modals      = {},
    accel            = 0,
    top_speed        = 0,
    start_coins      = 0,
    coins_unlocked   = false,
    laps             = 1,
    max_accel        = false,
    ghosts_unlocked  = false,
    ghost_efficiency = 1,
    skill_tree       = skill_tree.new(),
    drift            = 0,
    drift_boost      = 0,
    boost            = 0,
    magnet           = 0,
    active_track     = "track1",
    unlocked         = { track1 = true },
    tracks           = { track1 = track_data.default_track_state("track1", false) },
    car              = car.default_state(),
    race             = {
      next_checkpoint = 1,
      lap             = 1,
      time            = 0,
      phase           = "countdown",
      -- One collected-set per coin list (lap-1, lap-2); see scenes/race.
      coins_collected = { {}, {} },
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
    money          = State.money,
    seen_help      = State.seen_help,
    loop           = State.loop,
    -- Remaining loop-countdown seconds, persisted so a quit/reload resumes the
    -- clock where it left off (game time, not wall-clock) rather than at 5:00.
    loop_time_left = State.loop_time_left,
    seen_modals    = State.seen_modals,
    accel          = State.accel,
    -- top_speed / start_coins / coins_unlocked / laps / max_accel /
    -- ghost_efficiency are derived caches of the skill tree, and
    -- ghosts_unlocked of the loop
    -- counter, so none are saved. fx is transient render state, also dropped.
    -- (accel itself is race-shop progression and is saved, but Launch Control
    -- floors it at max on every rederive.)
    skill_tree     = {
      points    = State.skill_tree.points,
      ranks     = State.skill_tree.ranks,
      bought_at = State.skill_tree.bought_at,
    },
    drift          = State.drift,
    drift_boost    = State.drift_boost,
    boost          = State.boost,
    magnet         = State.magnet,
    active_track   = State.active_track,
    -- The tracks bought this loop. Cash-purchased and reset every loop (the
    -- climb), so it's real progression state and is saved to survive a mid-loop
    -- quit - not loop-derived.
    unlocked       = State.unlocked,
    tracks         = State.tracks,
  }
end

-- Applies a progression table (shape of `progression_of_state`) onto the
-- current State in place. Shared by the real load path and dev snapshot load.
local function apply_progression(loaded)
  State.money          = loaded.money or 0
  State.seen_help      = loaded.seen_help or false
  State.loop           = loaded.loop or 1
  -- Default a full clock for pre-existing saves that predate the field.
  State.loop_time_left = loaded.loop_time_left or track_data.LOOP_SECONDS
  State.seen_modals    = loaded.seen_modals or {}

  State.accel          = math.min(loaded.accel or 0, track_data.kind_max("accel") or 0)
  State.drift          = math.min(loaded.drift or 0, track_data.kind_max("drift") or 0)
  State.drift_boost    = math.min(loaded.drift_boost or 0, track_data.kind_max("drift_boost") or 0)
  State.boost          = math.min(loaded.boost or 0, track_data.kind_max("boost") or 0)
  State.magnet         = math.min(loaded.magnet or 0, track_data.kind_max("magnet") or 0)

  if loaded.active_track and track_data.TRACKS[loaded.active_track] then
    State.active_track = loaded.active_track
  end

  -- Restore the tracks bought this loop (cash-purchased, saved). Track 1 is
  -- always owned; seed default track state for each owned id.
  State.unlocked = { track1 = true }
  if loaded.unlocked then
    for id, owned in pairs(loaded.unlocked) do
      if owned and track_data.TRACKS[id] then
        State.unlocked[id] = true
      end
    end
  end
  for id in pairs(State.unlocked) do
    if not State.tracks[id] then
      State.tracks[id] = track_data.default_track_state(id, State.coins_unlocked)
    end
  end

  if loaded.tracks then
    for id, lt in pairs(loaded.tracks) do
      if track_data.TRACKS[id] then
        if not State.tracks[id] then
          State.tracks[id] = track_data.default_track_state(id, State.coins_unlocked)
        end
        local ts      = State.tracks[id]
        ts.ghost_line = lt.ghost_line
        ts.best_rate  = lt.best_rate
        ts.paid_rank  = lt.paid_rank or "D"
        ts.ghosts     = math.min(lt.ghosts or 0, track_data.kind_max("ghosts"))
        -- Raw here; both the coin ceiling and the start_coins floor need the
        -- skill tree, which loads below - rederive_skill_effects clamps at the
        -- end.
        ts.coins      = lt.coins or 0
        -- Raw here too; the coins2 ceiling needs the skill tree the same way.
        ts.coins2     = lt.coins2 or 0
        ts.extra_laps = math.min(lt.extra_laps or 0, track_data.kind_max("laps") or 0)
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

-- State.top_speed / State.start_coins / State.coins_unlocked / State.laps /
-- State.max_accel / State.ghost_efficiency are caches derived from the skill
-- tree; the tree is the single source of truth. State.ghosts_unlocked is the
-- exception: ghosts aren't bought at all, the story hands them over at loop 2
-- (scenes/intro's loop-2 beats announce them), so it's derived from the loop
-- counter - which every caller assigns before reaching here.
-- Re-derive after any rank change or load, before resync_car_and_ghosts pushes
-- results into the car and ghost sims. The coin ceiling/floor is applied live
-- to existing tracks so a rank bought at the loop gate takes effect that loop,
-- not the next.
function M.rederive_skill_effects()
  local ctx              = skill_tree.apply_all(State.skill_tree, {})
  State.top_speed        = ctx.top_speed or 0
  State.start_coins      = ctx.start_coins or 0
  State.coins_unlocked   = ctx.coins or false
  State.laps             = ctx.laps or 1
  State.max_accel        = ctx.max_accel or false
  State.ghosts_unlocked  = (State.loop or 1) >= 2
  State.ghost_efficiency = ctx.ghost_efficiency or 1
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
    -- Ceiling only - magenta gets no floor, Head Start is gold-only. The same
    -- protection falls out for free: max_coins2 is 0 without Loose Change, so
    -- a coinless save reads back with no magenta coins either.
    ts.coins2 = math.min(ts.coins2 or 0, track_data.max_coins2(id, State.coins_unlocked))
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

-- Rebirth resets and climbs again: everything resets to a fresh save except the
-- loop counter, dismissed tutorials, and the skill tree. The tree
-- carries this loop's ¥ - already banked per race rank (see
-- economy.bank_race_yen) - so there's no reward term here; the ¥ was earned as
-- the loop was raced and is now spent in the garage this reset drops into.
-- Fires only when the loop clock runs out (scenes/buy dismiss_timeout) - there's
-- no voluntary Rebirth; the player races the loop until time is up.
function M.start_new_loop()
  local next_loop     = (State.loop or 1) + 1
  local seen_help     = State.seen_help
  local seen_modals   = State.seen_modals
  local tree          = State.skill_tree
  State               = default_state()
  State.loop          = next_loop
  State.seen_help     = seen_help
  State.seen_modals   = seen_modals
  -- Carry the skill tree across the reset (like seen_help). fx is transient,
  -- rebuilt empty. Its points already include everything earned this loop.
  State.skill_tree    = tree
  State.skill_tree.fx = {}
  -- Ownership resets to Track 1 for the fresh climb (default_state already seeded
  -- unlocked = { track1 } and tracks.track1). The higher tracks are re-bought
  -- with cash this loop; the whole corridor is buyable regardless of loop. The
  -- tree (and its coin availability) survives the reset; the coin floor is
  -- applied by the rederive below.
  -- No fanfare here: the TIME'S UP modal that triggers the reset already served
  -- as it, and the buy scene routes on from there - to the garage on every loop
  -- but the first, which skips it (nothing was banked) for the title screen and
  -- loop 2's opening beats.
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
  -- would otherwise reload into buy and skip the gate. Resume the gate. Loop 3
  -- is the first loop reachable only through that garage (loop 1 ends without
  -- one at all), so an unbought Loose Change there means the player quit
  -- standing in it.
  if loaded and State.loop >= 3 and skill_tree.rank(State.skill_tree, "coins") == 0 then
    State.mode = "skill_tree"
  end
end

-- Dev-only: synthetic saves standing where a Rebirth would have dropped the
-- player at the top of a given loop, so the mid-game is reachable without
-- playing up to it. `progression` is the same shape apply_progression consumes
-- (sparse - anything omitted takes its default_state value), and `mode` is the
-- scene the real Rebirth routes to (scenes/buy dismiss_timeout). Enabled by the
-- DEV_SCENARIO global in main.lua.
local DEV_SCENARIOS = {
  -- Loop 2, exactly as loop 1's timeout leaves it: only the dismissed tutorials
  -- carry over. Loop 1 banks no ¥ (economy.bank_race_yen) and the climb resets
  -- to Track 1, so the tree is empty and there's nothing owned. Ghosts are on
  -- (derived from the loop counter) and the loop-2 opening beats haven't played,
  -- so this lands on the title screen like the real Rebirth does - no garage,
  -- since there's nothing banked to spend.
  loop2 = {
    mode        = "intro",
    progression = {
      loop        = 2,
      seen_help   = true,
      seen_modals = { shop = true },
    },
  },
  -- Loop 3, as loop 2's timeout leaves it: standing in the first garage the
  -- player ever reaches, with loop 2's ¥ unspent and Loose Change the only thing
  -- buyable (skill_tree's tutorial_gate). The ¥ is what a loop 2 that climbed to
  -- Track 2 banks - A on track 1 (60) plus B on track 2 (30), per
  -- economy.RANK_YEN. The garage explainer hasn't been seen yet, so it shows.
  loop3 = {
    mode        = "skill_tree",
    progression = {
      loop        = 3,
      seen_help   = true,
      seen_modals = { shop = true, ghosts = true },
      skill_tree  = { points = 90, ranks = {}, bought_at = {} },
    },
  },
  -- Multi-lap bench (docs/laps-plan.md). Mid-loop so bank_race_yen is live and
  -- ranks/¥ behave normally, every track owned and stocked to its full coin
  -- count, Victory Lap bought, and enough cash that the shop is never the
  -- gate. Parked on track 4: it's the only race long enough (10.6s on the
  -- reference line) for lap-2 coin placement to express itself -- track 2 is
  -- a six-second race, and two three-second laps prove nothing. Ghosts start
  -- at 0 so the "$/sec went up, not down" check has a clean before/after.
  -- ranks = { laps = 1 } only opens the shop rows now (the node is a ceiling,
  -- not a grant), so track 4's extra_laps and coins2 are seeded explicitly -
  -- otherwise the bench would boot single-lap and stop being a lap bench.
  laps = {
    mode        = "buy",
    progression = {
      loop         = 5,
      seen_help    = true,
      seen_modals  = { shop = true, ghosts = true, coins = true, magnet = true },
      money        = 50000,
      active_track = "track4",
      accel        = 4,
      drift        = 1,
      unlocked     = {
        track1 = true, track2 = true, track3 = true, track4 = true,
      },
      -- coins/coins2 are each list's own ceiling now, so every authored slot
      -- on both lists is live.
      tracks       = {
        track1 = { ghosts = 0, coins = 2, paid_rank = "D" },
        track2 = { ghosts = 0, coins = 4, paid_rank = "D" },
        track3 = { ghosts = 0, coins = 5, paid_rank = "D" },
        track4 = { ghosts = 0, coins = 5, coins2 = 5, extra_laps = 1, paid_rank = "D" },
      },
      skill_tree   = {
        points    = 200,
        ranks     = { coins = 1, start_coins = 1, laps = 1, top_speed = 1 },
        -- Bought loops back, so both downstream gates read as long satisfied
        -- if the garage is opened mid-test.
        bought_at = { coins = 2, start_coins = 3, laps = 3, top_speed = 3 },
      },
    },
  },
}

-- Dev-only: wipes State and rebuilds it as the named scenario, then saves - so
-- it survives the reload, and a later boot with DEV_SCENARIO cleared resumes the
-- scenario rather than whatever save it replaced.
function M.dev_start_scenario(name)
  local scn = DEV_SCENARIOS[name]
  if not scn then
    print("[dev] no scenario named '" .. tostring(name) .. "'")
    return
  end
  State = default_state()
  apply_progression(scn.progression)
  State.mode = scn.mode
  ghost.clear_all_sims()
  M.resync_car_and_ghosts()
  M.save()
  print("[dev] started scenario '" .. name .. "' (loop " .. State.loop .. ")")
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
