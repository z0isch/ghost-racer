local track1 = require "tile-map.track1"
local track2 = require "tile-map.track2"
local track3 = require "tile-map.track3"
local track4 = require "tile-map.track4"

local M      = {}

-- Reverse-driving prototype: horizontally mirrors every track (tile grid,
-- checkpoints, coins, spawn) and puts the car in reverse gear (release gas
-- to accelerate backwards). Spawn facing stays east, which lands facing away
-- from checkpoint 1 on the mirrored layout. Everything downstream (ghosts,
-- ranks, economy) runs unchanged on the mirrored data, so don't flip this on
-- a save that has forward ghost laps -- they'd clip through mirrored walls
-- and skew idle income. Snapshot via Dev: Save State and test on a fresh
-- save.
M.REVERSE_MODE  = false

M.tile_size     = track1.tilewidth

-- Coin-pickup radius (px) granted by each level of the "magnet" upgrade.
-- Level 0 (no magnet) falls back to plain box-overlap pickup instead of a
-- circle, so M.MAGNET_RADII[0] is intentionally absent (Lua indexes from 1).
M.MAGNET_RADII  = { 18, 24, 30 }

function M.magnet_radius(level)
  return M.MAGNET_RADII[level]
end

-- Seconds in a loop's countdown before it force-Rebirths. Tuning knob.
M.LOOP_SECONDS = 300

-- Fixed cash price of Nirvana, the always-available escape item (the eventual
-- win condition). Ungated - never keyed to rank/loop/track - and unreachable
-- for now; the buy button renders it trimmed to "$300m". Tuning knob.
M.NIRVANA_COST = 300000000   -- was 1000000

-- Car/player upgrades sold in the global UPGRADES column of the buy scene,
-- available on every track from the start. Later upgrades are gated purely
-- by price (plus drift_boost needing drift owned - see economy.try_buy).
M.UPGRADES     = {
  {
    kind      = "accel",
    label     = "Acceleration",
    max       = 4,
    base_cost = 10,
    growth    = 1.4
  },
  {
    kind      = "drift",
    label     = "Drift",
    max       = 1,
    base_cost = 400,
    growth    = 1.6
  },
  {
    kind      = "drift_boost",
    label     = "Drift Boost",
    max       = 1,
    base_cost = 500,
    growth    = 1.6
  },
  {
    kind      = "boost",
    label     = "Boost",
    max       = 5,
    base_cost = 2000,
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
    map           = track1,
    spawn         = { col = 5, row = 14 },
    checkpoints   = {
      { col = 31, row = 8, w = 4, h = 7 },
    },
    gates         = {
      { col = 10, row = 8, len = 7, vertical = true, mode = "reverse" },
      { col = 26, row = 8, len = 7, vertical = true, mode = "forward" },
    },
    coins         = {
      { col = 18, row = 9 },
      { col = 26, row = 9 },
    },
    base_coins    = 1,
    ranks         = { C = 1.0, B = 2.15, A = 2.65, S = 4 },
    -- Thresholds while coins are off (the Loose Change skill node isn't
    -- bought): checkpoint-and-ghost income only, so scaled way down.
    -- Provisional - tune freely.
    no_coin_ranks = { C = .8, B = 1.1, A = 1.5, S = 3 },
    label         = "Track 1",
    pay           = 5,
    -- Cash price to *buy* this track for the current loop. Track 1 is owned free
    -- at the start of every loop (nil), the rest are re-bought each climb. The
    -- whole corridor is buyable regardless of loop; cash is the only wall.
    unlock_cost   = nil,
    -- Cash price of a Rebirth taken *from* this track (the top owned track for
    -- the loop). Flat per track, no per-loop escalation - see the rebirth_cost
    -- table in the loop-track-gating plan.
    rebirth_cost  = 100,
    shop          = {
      {
        kind      = "ghosts",
        label     = "Ghost",
        currency  = "cash",
        max       = 8,
        base_cost = 5,
        growth    = 1.6
      },
      {
        kind      = "coins",
        label     = "Coin",
        currency  = "cash",
        base_cost = 18,
        growth    = 1.6
      },
    },
  },
  track2 = {
    map           = track2,
    spawn         = { col = 1, row = 9 },
    checkpoints   = {
      { col = 32, row = 12, w = 2, h = 5 },
      { col = 1,  row = 6,  w = 4, h = 11 },
    },
    gates         = {
      { col = 34, row = 6,  len = 5, vertical = true, mode = "reverse" },
      { col = 26, row = 12, len = 5, vertical = true, mode = "forward" },
    },
    coins         = {
      { col = 18, row = 7 },
      { col = 30, row = 14 },
      { col = 10, row = 16 },
      { col = 6,  row = 8 },
    },
    base_coins    = 3,
    ranks         = { C = 5.0, B = 6.5, A = 8.4, S = 11.0 },
    no_coin_ranks = { C = 2.5, B = 2.7, A = 3, S = 6.0 },
    label         = "Track 2",
    pay           = 15,
    unlock_cost   = 100,
    rebirth_cost  = 700,
    shop          = {
      {
        kind      = "checkpoints",
        label     = "Checkpoint",
        currency  = "cash",
        base_cost = 180,
        growth    = 1.3
      },
      {
        kind      = "ghosts",
        label     = "Ghost",
        currency  = "cash",
        max       = 8,
        base_cost = 150,
        growth    = 1.3
      },
      {
        kind      = "coins",
        label     = "Coin",
        currency  = "cash",
        base_cost = 300,
        growth    = 1.3
      },
    },
  },
  track3 = {
    map           = track3,
    spawn         = { col = 7, row = 3 },
    checkpoints   = {
      { col = 34, row = 14, w = 5, h = 2 },
      { col = 8,  row = 16, w = 2, h = 5 },
      { col = 1,  row = 1,  w = 5, h = 5 },
    },
    gates         = {
      { col = 14, row = 1,  len = 5, vertical = true, mode = "reverse" },
      { col = 29, row = 1,  len = 5, vertical = true, mode = "forward" },
      { col = 33, row = 16, len = 5, vertical = true, mode = "reverse" },
    },
    coins         = {
      { col = 36, row = 7 },
      { col = 10, row = 18 },
      { col = 24, row = 16 },
      { col = 3,  row = 11 },
      { col = 20, row = 3 },
    },
    base_coins    = 4,
    ranks         = { C = 12.0, B = 18.0, A = 22.0, S = 27.0 },
    no_coin_ranks = { C = 5, B = 8, A = 9.5, S = 20.0 },
    label         = "Track 3",
    pay           = 45,
    unlock_cost   = 700,
    rebirth_cost  = 3500,
    shop          = {
      {
        kind      = "checkpoints",
        label     = "Checkpoint",
        currency  = "cash",
        base_cost = 1000,
        growth    = 1.3
      },
      {
        kind      = "ghosts",
        label     = "Ghost",
        currency  = "cash",
        max       = 8,
        base_cost = 1000,
        growth    = 1.3
      },
      {
        kind      = "coins",
        label     = "Coin",
        currency  = "cash",
        base_cost = 1000,
        growth    = 1.3
      },
    },
  },
  track4 = {
    map           = track4,
    spawn         = { col = 20, row = 11 },
    checkpoints   = {
      { col = 34, row = 2,  w = 4, h = 4 },
      { col = 2,  row = 16, w = 4, h = 4 },
      { col = 2,  row = 2,  w = 4, h = 4 },
      { col = 34, row = 16, w = 4, h = 4 },
      { col = 18, row = 9,  w = 4, h = 4 }
    },
    coins         = {
      { col = 36, row = 12 },
      { col = 10, row = 18 },
      { col = 24, row = 16 },
      { col = 4,  row = 11 },
      { col = 10, row = 7 },
    },
    base_coins    = 4,
    ranks         = { C = 30.0, B = 60.0, A = 80.0, S = 89.0 },
    -- Scaled off `ranks` at roughly the ratio the other tracks use (~0.43 up
    -- to A, ~0.74 at S) - pure guesses, tune in playtest.
    no_coin_ranks = { C = 13.0, B = 26.0, A = 34.0, S = 66.0 },
    label         = "Track 4",
    pay           = 135,
    unlock_cost   = 3500,
    rebirth_cost  = 17500,
    shop          = {
      {
        kind      = "checkpoints",
        label     = "Checkpoint",
        currency  = "cash",
        base_cost = 9000,
        growth    = 1.3
      },
      {
        kind      = "ghosts",
        label     = "Ghost",
        currency  = "cash",
        max       = 8,
        base_cost = 9000,
        growth    = 1.3
      },
      {
        kind      = "coins",
        label     = "Coin",
        currency  = "cash",
        base_cost = 9000,
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

-- Rank thresholds for a track. Keyed on whether coins are unlocked (the
-- Loose Change skill node - see persist.rederive_skill_effects): a coinless
-- track pays checkpoints and ghosts only.
function M.ranks(id, has_coins)
  local tdata = M.TRACKS[id]
  return has_coins and tdata.ranks or tdata.no_coin_ranks
end

function M.rebirth_cost(id)
  return M.TRACKS[id].rebirth_cost
end

-- Cash price to buy a track for the current loop (nil for Track 1, owned free).
function M.unlock_cost(id)
  return M.TRACKS[id].unlock_cost
end

-- Ascending per-race rank letters above the D floor, checked against
-- M.ranks(id, has_coins).
local RANK_LETTERS = { "C", "B", "A", "S" }

-- Rank earned by a $/sec `rate` on a track, against the coinless or full
-- thresholds per `has_coins`. Below the lowest threshold is "D". Pure (no
-- State), so callers can reach it without pulling in economy (economy requires
-- persist, which requires track_data - a cycle). economy.rank_for_rate
-- delegates here.
function M.rank_for_rate(id, rate, has_coins)
  local thresholds = M.ranks(id, has_coins)
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
function M.max_coins(id, has_coins)
  if not has_coins then return 0 end
  return #M.TRACKS[id].coins
end

function M.default_track_state(id, has_coins, start_coins)
  return {
    ghost_line  = nil,
    best_rate   = nil,
    -- Highest rank tier already paid ¥ for on this track this loop, the
    -- high-water mark that keeps race-¥ credited once per tier (see
    -- economy.bank_race_yen). Resets with the loop (fresh track state).
    paid_rank   = "D",
    ghosts      = 0,
    coins       = M.start_coin_floor(id, has_coins, start_coins),
    checkpoints = 1,
  }
end

return M
