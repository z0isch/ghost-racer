local track1   = require "tile-map.track1"
local track2   = require "tile-map.track2"
local track3   = require "tile-map.track3"
local track4   = require "tile-map.track4"

local M        = {}

-- Reverse-driving prototype: horizontally mirrors every track (tile grid,
-- checkpoints, coins, spawn) and unlocks the flip (double-tap BTN1) that puts
-- the car in reverse gear, where the always-on throttle accelerates it
-- backwards. Spawn facing stays east, which lands facing away from checkpoint 1
-- on the mirrored layout, so the car also *starts* in reverse gear (car.lua's
-- START_GEAR) and pulls toward checkpoint 1 off the line. The level palette
-- swaps to its own darker teal theme to match (road.lua PALETTES). Everything downstream (ghosts,
-- ranks, economy) runs unchanged on the mirrored data, so don't flip this on
-- a save that has forward ghost laps -- they'd clip through mirrored walls
-- and skew idle income. Snapshot via Dev: Save State and test on a fresh
-- save.
M.REVERSE_MODE = false

M.tile_size    = track1.tilewidth

-- Coin-pickup radius (px) granted by each level of the "magnet" upgrade.
-- Level 0 (no magnet) falls back to plain box-overlap pickup instead of a
-- circle, so M.MAGNET_RADII[0] is intentionally absent (Lua indexes from 1).
M.MAGNET_RADII = { 18, 24, 30 }

function M.magnet_radius(level)
  return M.MAGNET_RADII[level]
end

-- Seconds in a loop's countdown before it force-Rebirths. Tuning knob.
M.LOOP_SECONDS  = 300

-- Multi-lap knobs (see docs/laps-plan.md). Both start at 2x rather than
-- something gentler: the lap-2 payoff has to be unmistakable for the fun test
-- to read at all.
--
-- The asymmetry between the two is load-bearing, not an implementation detail.
-- LAP_COIN_MULT is *list*-attached: a `coins2` coin pays it whenever it's
-- grabbed, and a `coins` coin always pays 1x, including when swept up on lap 2.
-- Applying a multiplier at collection time instead would make skipping lap-1
-- coins strictly better whenever the detour is cheap -- rank is pure $/sec, so
-- the optimal line would stop being "race well" and become "drive past coins on
-- purpose". LAP_CP_MULT is *lap*-attached, which is safe because checkpoints
-- are mandatory and in-order: there's nothing to sandbag.
M.LAP_COIN_MULT = 3
M.LAP_CP_MULT   = 3

-- Fixed cash price of Nirvana, the always-available escape item (the eventual
-- win condition). Ungated - never keyed to rank/loop/track - and unreachable
-- for now; the buy button renders it trimmed to "$300m". Tuning knob.
M.NIRVANA_COST  = 300000000 -- was 1000000

-- Car/player upgrades sold in the global UPGRADES column of the buy scene,
-- available on every track from the start. Later upgrades are gated purely
-- by price (plus drift_boost needing drift owned - see economy.try_buy).
M.UPGRADES      = {
  {
    kind      = "accel",
    label     = "Acceleration",
    max       = 4,
    base_cost = 5,
    growth    = 1.4
  },
  {
    kind      = "drift",
    label     = "Drift",
    max       = 1,
    base_cost = 75,
    growth    = 1.6
  },
  {
    kind      = "drift_boost",
    label     = "Drift Boost",
    max       = 1,
    base_cost = 100,
    growth    = 1.6
  },
  {
    kind      = "boost",
    label     = "Boost",
    max       = 5,
    base_cost = 450,
    growth    = 1.3
  },
  {
    kind      = "magnet",
    label     = "Coin Magnet",
    max       = 3,
    base_cost = 4000,
    growth    = 1.3
  },
}

function M.upgrades()
  return M.UPGRADES
end

function M.upgrade_item(kind)
  for _, item in ipairs(M.upgrades()) do
    if item.kind == kind then return item end
  end
  return nil
end

-- Per-track rank thresholds (`ranks`) are $/sec on a single race:
-- pay * (weighted checkpoint crossings + weighted coin pickups) / race time,
-- with lap-2 crossings worth LAP_CP_MULT and every `coins2` pickup worth
-- LAP_COIN_MULT. They're derived from that track's reference lap
-- (data/ref_<id>.json: arc length L and clean lap time T at the top speed the
-- capture ran at, 220 = TOP_VEL_BASE + 2 Engine Tune ranks), so each tier is
-- "the coin haul the tier names, driven at the pace the car of that era can
-- hold", with the threshold set 12% under that ideal run so a good-but-not-
-- perfect lap still earns it:
--
--   C  course only, no coins,      base car   (120 px/s, no Engine Tune)
--   B  half the buyable coins,     1 tune     (170 px/s)
--   A  every buyable gold coin,    2 tunes    (220 px/s, reference pace)
--   S  A's lap plus a second one sweeping every buyable coins2 coin
--
-- Lap time at top speed v is T * 220/v; a coin's detour costs 2x its
-- perpendicular distance off the reference line at that lap's average speed
-- (gold sits on the line almost everywhere, so A is nearly free time-wise;
-- coins2 is authored off-line on purpose and lap 2 pays for it).
--
-- Two things the tiers deliberately do *not* do. C stays inside reach of a
-- base-speed car on every track: rank is the only ¥ source (economy.RANK_YEN),
-- so a corridor where the un-tuned car ranks D everywhere would lock the tree
-- shut. And the coin sets counted are the *buyable* ones (base_coins from each
-- list) rather than the full authored lists - Head Start's extra gold coin has
-- to be a cushion on top of a tier, never the thing a tier requires. Track 1 is
-- the exception at S: it has no second lap, so its S is both gold coins (Head
-- Start included) at reference pace.
M.TRACKS = {
  track1 = {
    map         = track1,
    spawn       = { col = 5, row = 14 },
    checkpoints = {
      { col = 31, row = 8, w = 4, h = 7 },
    },
    gates       = {
      { col = 10, row = 8, len = 7, vertical = true, mode = "reverse" },
      { col = 26, row = 8, len = 7, vertical = true, mode = "forward" },
    },
    coins       = {
      { col = 18, row = 9 },
      { col = 26, row = 9 },
    },
    base_coins  = 1,
    ranks       = { C = 1.05, B = 2.25, A = 4.3, S = 6.4 },
    label       = "Track 1",
    pay         = 5,
    -- Cash price to *buy* this track for the current loop. Track 1 is owned free
    -- at the start of every loop (nil), the rest are re-bought each climb. The
    -- whole corridor is buyable regardless of loop; cash is the only wall.
    unlock_cost = nil,
    shop        = {
      {
        kind      = "ghosts",
        label     = "Ghost",
        currency  = "cash",
        max       = 5,
        base_cost = 5,
        growth    = 1.6
      },
      {
        kind      = "coins",
        label     = "Coin",
        currency  = "cash",
        base_cost = 10,
        growth    = 1.6
      },
    },
  },
  track2 = {
    map         = track2,
    spawn       = { col = 1, row = 9 },
    checkpoints = {
      { col = 32, row = 12, w = 2, h = 5 },
      { col = 1,  row = 6,  w = 4, h = 11 },
    },
    gates       = {
      { col = 34, row = 6,  len = 5, vertical = true, mode = "reverse" },
      { col = 26, row = 12, len = 5, vertical = true, mode = "forward" },
    },
    coins       = {
      { col = 18, row = 7 },
      { col = 30, row = 14 },
      { col = 10, row = 16 },
      { col = 6,  row = 8 },
    },
    -- A wide room (rows 6-16) with a center bar at row 11: it races as an oval,
    -- and the fast line hugs the inside of each lane. Off-line is therefore the
    -- outer edge, rows 6 and 16.
    coins2      = {
      { col = 12, row = 6 },  -- top lane, outermost, mid-left
      { col = 26, row = 6 },  -- top lane, outermost, mid-right
      { col = 20, row = 16 }, -- bottom lane, outermost
      { col = 36, row = 16 }, -- deep bottom-right corner, overshooting cp1
    },
    laps        = 2,
    base_coins  = 3,
    ranks       = { C = 2.6, B = 6.9, A = 11.0, S = 22.0 },
    label       = "Track 2",
    pay         = 15,
    unlock_cost = 25,
    shop        = {
      {
        kind      = "ghosts",
        label     = "Ghost",
        currency  = "cash",
        max       = 8,
        base_cost = 20,
        growth    = 1.3
      },
      {
        kind      = "coins",
        label     = "Coin",
        currency  = "cash",
        base_cost = 50,
        growth    = 1.3
      },
      {
        kind      = "laps",
        label     = "Extra Lap",
        currency  = "cash",
        max       = 1,
        base_cost = 75
      },
    },
  },
  track3 = {
    map         = track3,
    spawn       = { col = 7, row = 3 },
    checkpoints = {
      { col = 34, row = 14, w = 5, h = 2 },
      { col = 8,  row = 16, w = 2, h = 5 },
      { col = 1,  row = 1,  w = 5, h = 5 },
    },
    gates       = {
      { col = 14, row = 1,  len = 5, vertical = true,  mode = "reverse" },
      { col = 29, row = 1,  len = 5, vertical = true,  mode = "forward" },
      { col = 33, row = 16, len = 5, vertical = true,  mode = "reverse" },
      { col = 17, row = 10, len = 3, vertical = true,  mode = "forward" },
      { col = 6,  row = 16, len = 5, vertical = true,  mode = "reverse" },
      { col = 1,  row = 8,  len = 5, vertical = false, mode = "forward" },
    },
    coins       = {
      { col = 36, row = 7 },
      { col = 10, row = 18 },
      { col = 24, row = 16 },
      { col = 3,  row = 11 },
      { col = 20, row = 3 },
    },
    -- The route is the outer ring. The inner chamber (rows 10-14, cols 10-21,
    -- reachable only from below) is territory the ring never touches, so it's
    -- the ideal lap-2 detour here; three coins spread across it make a mini
    -- route inside rather than one cluster to clip.
    coins2      = {
      { col = 11, row = 10 }, -- inner chamber, upper-left
      { col = 21, row = 12 }, -- inner chamber, right
      { col = 13, row = 14 }, -- inner chamber, lower-left
      { col = 36, row = 19 }, -- top-right outer corner, outside the turn
      { col = 28, row = 19 }, -- bottom band, deep below the inner line
    },
    laps        = 2,
    base_coins  = 4,
    ranks       = { C = 8.0, B = 19.0, A = 34.0, S = 65.0 },
    label       = "Track 3",
    pay         = 45,
    unlock_cost = 200,
    shop        = {
      {
        kind      = "ghosts",
        label     = "Ghost",
        currency  = "cash",
        max       = 8,
        base_cost = 200,
        growth    = 1.3
      },
      {
        kind      = "coins",
        label     = "Coin",
        currency  = "cash",
        base_cost = 500,
        growth    = 1.3
      },
      {
        kind      = "laps",
        label     = "Extra Lap",
        currency  = "cash",
        max       = 1,
        base_cost = 750
      },
    },
  },
  track4 = {
    map         = track4,
    spawn       = { col = 20, row = 11 },
    checkpoints = {
      { col = 34, row = 2,  w = 4, h = 4 },
      { col = 2,  row = 16, w = 4, h = 4 },
      { col = 2,  row = 2,  w = 4, h = 4 },
      { col = 34, row = 16, w = 4, h = 4 },
      { col = 18, row = 9,  w = 4, h = 4 }
    },
    coins       = {
      { col = 36, row = 12 },
      { col = 10, row = 18 },
      { col = 24, row = 16 },
      { col = 4,  row = 11 },
      { col = 10, row = 7 },
    },
    -- An empty box with the four corners plus center as checkpoints, so the
    -- route is a star crossing the middle over and over. The dead zones are
    -- top-center, bottom-center, and the mid-edge pockets between diagonals.
    coins2      = {
      { col = 20, row = 2 },  -- top center
      { col = 20, row = 19 }, -- bottom center
      { col = 10, row = 3 },  -- upper-left, above the cp3->cp4 diagonal
      { col = 32, row = 10 }, -- right pocket, between the cp5->cp1 and cp4->cp5 legs
      { col = 8,  row = 11 }, -- left, midway between the two main diagonals
    },
    laps        = 2,
    base_coins  = 4,
    ranks       = { C = 30.0, B = 61.0, A = 100.0, S = 178.0 },
    label       = "Track 4",
    pay         = 135,
    unlock_cost = 1200,
    shop        = {
      {
        kind      = "ghosts",
        label     = "Ghost",
        currency  = "cash",
        max       = 8,
        base_cost = 1500,
        growth    = 1.3
      },
      {
        kind      = "coins",
        label     = "Coin",
        currency  = "cash",
        base_cost = 3000,
        growth    = 1.3
      },
      {
        kind      = "laps",
        label     = "Extra Lap",
        currency  = "cash",
        max       = 1,
        base_cost = 4500
      },
    },
  },
}

-- Left-right flip of a Tiled map's single tile layer. Tiles are flat color
-- fills (see road.tile_colors), so mirroring the grid needs no per-tile
-- sprite flipping. Returns a copy; the required map modules stay pristine.
local function mirror_map(map)
  local src    = map.layers[1].data
  local mw, mh = map.width, map.height
  local data   = {}
  for row = 0, mh - 1 do
    for col = 0, mw - 1 do
      data[row * mw + col + 1] = src[row * mw + (mw - 1 - col) + 1]
    end
  end
  local mirrored = {}
  for k, v in pairs(map) do mirrored[k] = v end
  mirrored.layers = { { data = data } }
  return mirrored
end

-- Produces a track's mirrored twin and leaves the input pristine, so both
-- orientations of a track can exist at once (see M.mirrored). Fields that
-- aren't position-dependent -- ranks, pay, shop, laps -- ride across by
-- reference; every geometric one is rebuilt.
local function mirror_track(tdata)
  local mw  = tdata.map.width
  local out = {}
  for k, v in pairs(tdata) do out[k] = v end
  out.map           = mirror_map(tdata.map)
  out.spawn         = { col = mw - 1 - tdata.spawn.col, row = tdata.spawn.row }

  local checkpoints = {}
  for i, cp in ipairs(tdata.checkpoints) do
    checkpoints[i] = { col = mw - cp.col - cp.w, row = cp.row, w = cp.w, h = cp.h }
  end
  out.checkpoints = checkpoints

  local coins     = {}
  for i, coin in ipairs(tdata.coins) do
    coins[i] = { col = mw - 1 - coin.col, row = coin.row }
  end
  out.coins = coins

  if tdata.coins2 then
    local coins2 = {}
    for i, coin in ipairs(tdata.coins2) do
      coins2[i] = { col = mw - 1 - coin.col, row = coin.row }
    end
    out.coins2 = coins2
  end

  if tdata.gates then
    local gates = {}
    for i, g in ipairs(tdata.gates) do
      -- Mode is untouched: hood-first vs trunk-first is mirror-invariant.
      gates[i] = {
        col      = g.vertical and mw - 1 - g.col or mw - g.col - g.len,
        row      = g.row,
        len      = g.len,
        vertical = g.vertical,
        mode     = g.mode,
      }
    end
    out.gates = gates
  end
  return out
end

-- Mirrored variants, built on first request and cached. A mirrored track is a
-- second *place* rather than a mode: asking for one never disturbs the forward
-- data, so a reverse corridor can be driven while forward ghost lines stay
-- valid. REVERSE_MODE is the degenerate case of that, below.
local MIRRORED = {}

function M.mirrored(id)
  if not MIRRORED[id] then MIRRORED[id] = mirror_track(M.TRACKS[id]) end
  return MIRRORED[id]
end

-- REVERSE_MODE re-expressed on top of M.mirrored: swap each track for its twin
-- at load. Same observable behavior as the old in-place mutation -- one set of
-- track data, all-forward or all-reverse for the lifetime of the run -- with no
-- call site aware of it.
if M.REVERSE_MODE then
  local ids = {}
  for id in pairs(M.TRACKS) do ids[#ids + 1] = id end
  for _, id in ipairs(ids) do M.TRACKS[id] = M.mirrored(id) end
end

-- Full authored track order. A track flagged `hidden = true` exists in TRACKS
-- (raceable, unlockable if reached) but is excluded from the visible corridor:
-- it's never offered as the "next track" row and `>` nav skips it, so future
-- hidden/discovered tracks slot in without reworking reveal. Nothing sets it
-- yet - it's data-model plumbing for the parked true-end.
M.TRACK_ORDER = { "track1", "track2", "track3", "track4" }

-- The visible corridor: TRACK_ORDER with hidden tracks filtered out. Every
-- track exists in the corridor from the start; which ones are *owned* is
-- cash-bought (see economy.try_unlock_track), so the order never depends on the
-- loop.
function M.track_order()
  local out = {}
  for _, id in ipairs(M.TRACK_ORDER) do
    if not M.TRACKS[id].hidden then out[#out + 1] = id end
  end
  return out
end

function M.shop(id)
  return M.TRACKS[id].shop
end

-- Rank thresholds for a track.
function M.ranks(id)
  return M.TRACKS[id].ranks
end

-- Laps a race on this track runs: the min of three independent gates. Victory
-- Lap (State.laps) sets a ceiling on how many laps may be *purchased*, not a
-- grant - the lap itself is bought per track, per loop, tracked as
-- ts.extra_laps. The track's own `laps` field is its own ceiling. Track 1 has
-- no `laps` field and so stays single-lap without a special case anywhere --
-- it has exactly one checkpoint, so on lap 2 the next target would be the rect
-- the car is already sitting in and the race would end on the same frame.
-- The `(State.tracks[id] or {})` guard matters: road.draw_coins reaches this on
-- the buy-screen preview, and economy.try_unlock_track seeds track state after
-- State.unlocked[id] is already set.
function M.effective_laps(id)
  local bought = (State.tracks[id] or {}).extra_laps or 0
  return math.min(1 + bought, State.laps or 1, M.TRACKS[id].laps or 1)
end

-- Payout multiplier on a checkpoint crossed on `lap` (1-based).
function M.lap_mult(lap)
  return lap > 1 and M.LAP_CP_MULT or 1
end

-- Cash price to buy a track for the current loop (nil for Track 1, owned free).
function M.unlock_cost(id)
  return M.TRACKS[id].unlock_cost
end

-- Ascending per-race rank letters above the D floor, checked against
-- M.ranks(id).
local RANK_LETTERS = { "C", "B", "A", "S" }

-- Rank earned by a $/sec `rate` on a track. Below the lowest threshold is "D".
-- Pure (no State), so callers can reach it without pulling in economy (economy
-- requires persist, which requires track_data - a cycle). economy.rank_for_rate
-- delegates here.
function M.rank_for_rate(id, rate)
  local thresholds = M.ranks(id)
  local rank       = "D"
  if rate and rate > 0 then
    for _, letter in ipairs(RANK_LETTERS) do
      if rate >= thresholds[letter] then rank = letter end
    end
  end
  return rank
end

-- Where a $/sec `rate` sits along the whole D->S ladder, as a 0..1 fraction:
-- each rank owns an equal fifth and the rate interpolates between its own
-- thresholds inside that fifth, so two runs at the same rank still land at
-- different places. The S zone runs to twice the S threshold, so a monster run
-- eases toward the right edge instead of pinning to it at the first S.
--
-- Pure (no State), like M.rank_for_rate. Both the race HUD's needle and the
-- loop-end breakdown's arrows are placed with it, which is what makes "how far
-- along the bar" mean the same thing mid-race and at the loop-end table.
function M.rank_fraction(id, rate)
  local t      = M.ranks(id)
  local bounds = { 0, t.C, t.B, t.A, t.S, t.S * 2 }
  local n      = #bounds - 1
  rate         = rate or 0
  if rate >= bounds[n + 1] then return 1 end
  for i = n, 1, -1 do
    if rate >= bounds[i] then
      return (i - 1) / n + ((rate - bounds[i]) / (bounds[i + 1] - bounds[i])) / n
    end
  end
  return 0
end

function M.track_shop_item(track_id, kind)
  for _, item in ipairs(M.shop(track_id)) do
    if item.kind == kind then return item end
  end
  return nil
end

function M.kind_max(kind)
  local upgrade = M.upgrade_item(kind)
  if upgrade then return upgrade.max end
  for _, tid in ipairs(M.TRACK_ORDER) do
    local item = M.track_shop_item(tid, kind)
    if item then return item.max end
  end
  return nil
end

-- Corridor position of a track (its "Track #N" number), skipping hidden
-- tracks so numbering matches the visible order.
function M.get_track_index(id)
  local i = 0
  for _, tid in ipairs(M.TRACK_ORDER) do
    if not M.TRACKS[tid].hidden then
      i = i + 1
      if tid == id then return i end
    end
  end
  return 1
end

function M.coin_rect(coin)
  local ts = M.tile_size
  return { x = coin.col * ts, y = coin.row * ts, w = ts, h = ts }
end

function M.checkpoint_rect(cp)
  local ts = M.tile_size
  return { x = cp.col * ts, y = cp.row * ts, w = cp.w * ts, h = cp.h * ts }
end

-- Coins the shop will sell on a track: none until the Loose Change skill node
-- is bought, base_coins after. Head Start freebies never change this - they
-- sit on top of the buyable set, not inside it.
function M.buyable_coins(id, has_coins)
  if not has_coins then return 0 end
  return M.TRACKS[id].base_coins
end

-- Coins active for free from the start: one per Head Start (start_coins)
-- skill rank, filling only the authored slots left over after the buyable
-- set so buying the full base_coins is always possible.
function M.start_coin_floor(id, has_coins, start_coins)
  local spare = M.max_coins(id, has_coins) - M.buyable_coins(id, has_coins)
  return math.max(0, math.min(start_coins or 0, spare))
end

-- Highest total gold-coin count reachable on a track: none without Loose
-- Change, the full authored list with it (the slots beyond base_coins are
-- reachable only via Head Start, which sits downstream of Loose Change in the
-- tree). Gold-only now that each coin list is sold and clamped independently
-- - see M.max_coins2 for the magenta twin.
function M.max_coins(id, has_coins)
  if not has_coins then return 0 end
  return #M.TRACKS[id].coins
end

-- Highest total magenta-coin count reachable on a track: 0 without Loose
-- Change (same gate as gold) and 0 on any track with no `coins2` list at all.
function M.max_coins2(id, has_coins)
  if not has_coins then return 0 end
  return #(M.TRACKS[id].coins2 or {})
end

-- Magenta coins the shop will sell on a track: base_coins once the track has
-- a coins2 list at all, else 0 (no lap-2 coins to sell on a non-lap track).
-- No Head Start freebie here - Head Start is gold-only by decision. These are
-- sold through the same Coin row as gold, after the gold set runs out and only
-- once the Extra Lap is bought - see economy.next_coin_field.
function M.buyable_coins2(id, has_coins)
  if not has_coins then return 0 end
  local tdata = M.TRACKS[id]
  if not tdata.coins2 then return 0 end
  return tdata.base_coins
end

function M.default_track_state(id, has_coins, start_coins)
  return {
    ghost_line = nil,
    best_rate  = nil,
    -- Highest rank tier already paid ¥ for on this track this loop, the
    -- high-water mark that keeps race-¥ credited once per tier (see
    -- economy.bank_race_yen). Resets with the loop (fresh track state).
    paid_rank  = "D",
    ghosts     = 0,
    coins      = M.start_coin_floor(id, has_coins, start_coins),
    -- Laps purchased this loop, per track (0 or 1 today - see M.effective_laps).
    extra_laps = 0,
    -- Magenta coins bought this loop. No floor: Head Start is gold-only.
    coins2     = 0,
  }
end

return M
