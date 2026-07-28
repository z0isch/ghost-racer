local track1   = require "tile-map.track1"
local track2   = require "tile-map.track2"
local track3   = require "tile-map.track3"
local track4   = require "tile-map.track4"

local M        = {}

-- Reverse-driving prototype: horizontally mirrors every track (tile grid,
-- checkpoints, coins, spawn) and unlocks the flip (double-tap BTN1) that puts
-- the car in reverse gear, where the always-on throttle accelerates it
-- backwards. Spawn facing stays east, which lands facing away from checkpoint 1
-- on the mirrored layout, so the first move is a flip. Everything downstream (ghosts,
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
M.LOOP_SECONDS = 300

-- Multi-lap prototype knobs (see docs/laps-prototype-plan.md). Both start at 2x
-- rather than something gentler: the lap-2 payoff has to be unmistakable for
-- the fun test to read at all.
--
-- The asymmetry between the two is load-bearing, not an implementation detail.
-- LAP_COIN_MULT is *list*-attached: a `coins2` coin pays it whenever it's
-- grabbed, and a `coins` coin always pays 1x, including when swept up on lap 2.
-- Applying a multiplier at collection time instead would make skipping lap-1
-- coins strictly better whenever the detour is cheap -- rank is pure $/sec, so
-- the optimal line would stop being "race well" and become "drive past coins on
-- purpose". LAP_CP_MULT is *lap*-attached, which is safe because checkpoints
-- are mandatory and in-order: there's nothing to sandbag.
M.LAP_COIN_MULT = 2
M.LAP_CP_MULT   = 2

-- Fixed cash price of Nirvana, the always-available escape item (the eventual
-- win condition). Ungated - never keyed to rank/loop/track - and unreachable
-- for now; the buy button renders it trimmed to "$300m". Tuning knob.
M.NIRVANA_COST = 300000000 -- was 1000000

-- Car/player upgrades sold in the global UPGRADES column of the buy scene,
-- available on every track from the start. Later upgrades are gated purely
-- by price (plus drift_boost needing drift owned - see economy.try_buy).
M.UPGRADES     = {
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
    ranks       = { C = 1.05, B = 2.15, A = 2.65, S = 4 },
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
    ranks       = { C = 2.6, B = 6.5, A = 8.4, S = 11.0 },
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
      { col = 14, row = 1,  len = 5, vertical = true, mode = "reverse" },
      { col = 29, row = 1,  len = 5, vertical = true, mode = "forward" },
      { col = 33, row = 16, len = 5, vertical = true, mode = "reverse" },
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
      { col = 36, row = 2 },  -- top-right outer corner, outside the turn
      { col = 28, row = 19 }, -- bottom band, deep below the inner line
    },
    laps        = 2,
    base_coins  = 4,
    ranks       = { C = 9.0, B = 18.0, A = 22.0, S = 27.0 },
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
    ranks       = { C = 30.0, B = 60.0, A = 80.0, S = 89.0 },
    label       = "Track 4",
    pay         = 135,
    unlock_cost = 1500,
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

local function mirror_track(tdata)
  local mw          = tdata.map.width
  tdata.map         = mirror_map(tdata.map)
  tdata.spawn       = { col = mw - 1 - tdata.spawn.col, row = tdata.spawn.row }
  local checkpoints = {}
  for i, cp in ipairs(tdata.checkpoints) do
    checkpoints[i] = { col = mw - cp.col - cp.w, row = cp.row, w = cp.w, h = cp.h }
  end
  tdata.checkpoints = checkpoints
  local coins       = {}
  for i, coin in ipairs(tdata.coins) do
    coins[i] = { col = mw - 1 - coin.col, row = coin.row }
  end
  tdata.coins = coins
  if tdata.coins2 then
    local coins2 = {}
    for i, coin in ipairs(tdata.coins2) do
      coins2[i] = { col = mw - 1 - coin.col, row = coin.row }
    end
    tdata.coins2 = coins2
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
    tdata.gates = gates
  end
end

if M.REVERSE_MODE then
  for _, tdata in pairs(M.TRACKS) do mirror_track(tdata) end
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

-- Laps a race on this track runs. The per-track `laps` field is a *ceiling*,
-- not a switch: Victory Lap turns laps on globally (State.laps), and a track
-- opts in by declaring how many it can support. Track 1 has no `laps` field and
-- so stays single-lap without a special case anywhere -- it has exactly one
-- checkpoint, so on lap 2 the next target would be the rect the car is already
-- sitting in and the race would end on the same frame. Reading the field as a
-- ceiling also means laps can be disabled per-track during tuning by editing
-- data rather than code.
function M.effective_laps(id)
  return (State.laps or 1) > 1 and (M.TRACKS[id].laps or 1) or 1
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

-- Highest total coin count reachable on a track: none without Loose Change,
-- the full authored list with it (the slots beyond base_coins are reachable
-- only via Head Start, which sits downstream of Loose Change in the tree).
--
-- `tstate.coins` is one count with prefix semantics shared by both lists (Coin
-- #k lights lap-1 slot k *and* lap-2 slot k), so the ceiling is the longer
-- list. Taking only #coins would leave a dead tail on any track whose coins2
-- is longer: persist clamps ts.coins to this, so those slots would be
-- unreachable even with Head Start.
function M.max_coins(id, has_coins)
  if not has_coins then return 0 end
  local tdata = M.TRACKS[id]
  return math.max(#tdata.coins, #(tdata.coins2 or {}))
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
  }
end

return M
