local basic_map = require "tile-map.basic"
local track1    = require "tile-map.track1"
local track2    = require "tile-map.track2"
local track4    = require "tile-map.track4"

local M         = {}

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

-- Car/player upgrades sold in the global UPGRADES column of the buy scene,
-- available on every track from the start. Later upgrades are gated purely
-- by price (plus drift_boost needing drift owned - see economy.try_buy).
M.UPGRADES           = {
  {
    kind      = "accel",
    label     = "Acceleration",
    max       = 4,
    base_cost = 20,
    growth    = 1.4
  },
  {
    kind      = "drift",
    label     = "Drift",
    max       = 1,
    base_cost = 700,
    growth    = 1.6
  },
  {
    kind      = "drift_boost",
    label     = "Drift Boost",
    max       = 1,
    base_cost = 800,
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
    base_cost = 11000,
    growth    = 1.3
  },
}

-- Loop-1 prologue variant: checkpoint-only economy, so prices are scaled way
-- down, and no magnet (coins don't exist until loop 2).
local LOOP1_UPGRADES = {
  {
    kind      = "accel",
    label     = "Acceleration",
    max       = 4,
    base_cost = 10,
    growth    = 1.42
  },
  {
    kind      = "drift",
    label     = "Drift",
    max       = 1,
    base_cost = 90,
    growth    = 1.6
  },
  {
    kind      = "drift_boost",
    label     = "Drift Boost",
    max       = 1,
    base_cost = 150,
    growth    = 1.6
  },
  {
    kind      = "boost",
    label     = "Boost",
    max       = 5,
    base_cost = 300,
    growth    = 1.3
  },
}

function M.upgrades(loop)
  return loop == 1 and LOOP1_UPGRADES or M.UPGRADES
end

function M.upgrade_item(kind, loop)
  for _, item in ipairs(M.upgrades(loop)) do
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
    ranks       = { C = 1.0, B = 2.15, A = 2.75, S = 4.4 },
    label       = "Track 1",
    pay         = 5,
    unlock_cost = nil,
    shop        = {
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
        base_cost = 25,
        growth    = 1.6
      },
    },
    -- Loop-1 prologue overrides: checkpoint-only income (no ghosts, no
    -- coins - the shop is empty and car upgrades live in the global
    -- UPGRADES column), so ranks are scaled way down. Values are
    -- provisional - tune freely.
    loop1       = {
      ranks = { C = 1.0, B = 1.27, A = 1.5, S = 3 },
      shop  = {},
    },
  },
  basic = {
    map         = basic_map,
    spawn       = { col = 1, row = 9 },
    checkpoints = {
      { col = 33, row = 12, w = 2, h = 5 },
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
    base_coins  = 3,
    ranks       = { C = 5.0, B = 7.8, A = 8.2, S = 12.0 },
    label       = "Track 2",
    pay         = 15,
    unlock_cost = 250,
    shop        = {
      {
        kind      = "checkpoints",
        label     = "Checkpoint",
        currency  = "cash",
        base_cost = 400,
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
        base_cost = 400,
        growth    = 1.3
      },
    },
    -- Loop-1 prologue overrides - provisional, tune freely.
    loop1       = {
      unlock_cost = 28,
      ranks       = { C = 2.8, B = 3.2, A = 3.5, S = 6.0 },
      shop        = {
        {
          kind      = "checkpoints",
          label     = "Checkpoint",
          currency  = "cash",
          base_cost = 30,
          growth    = 1.3
        },
      },
    },
  },
  track2 = {
    map         = track2,
    spawn       = { col = 7, row = 3 },
    checkpoints = {
      { col = 34, row = 14, w = 5, h = 2 },
      { col = 8,  row = 16, w = 2, h = 5 },
      { col = 1,  row = 1,  w = 5, h = 5 },
    },
    coins       = {
      { col = 36, row = 11 },
      { col = 10, row = 18 },
      { col = 24, row = 16 },
      { col = 3,  row = 11 },
      { col = 20, row = 3 },
    },
    base_coins  = 4,
    ranks       = { C = 12.0, B = 18.0, A = 30.0, S = 33.0 },
    label       = "Track 3",
    pay         = 45,
    unlock_cost = 2500,
    shop        = {
      {
        kind      = "checkpoints",
        label     = "Checkpoint",
        currency  = "cash",
        base_cost = 1200,
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
        base_cost = 1100,
        growth    = 1.3
      },
    },
    -- Loop-1 prologue overrides - provisional, tune freely. Nirvana lives
    -- here in loop 1 (Track 4 doesn't exist yet) and needs rank A on every
    -- prologue track instead of S on this one.
    loop1       = {
      unlock_cost = 200,
      ranks       = { C = 10.0, B = 11.0, A = 12.0, S = 20.0 },
      shop        = {
        {
          kind      = "checkpoints",
          label     = "Checkpoint",
          currency  = "cash",
          base_cost = 120,
          growth    = 1.3
        },
        {
          kind              = "nirvana",
          label             = "Nirvana",
          currency          = "cash",
          max               = 1,
          base_cost         = 0,
          growth            = 1,
          requires_rank_all = "A"
        },
      },
    },
  },
  track4 = {
    map                = track4,
    spawn              = { col = 20, row = 11 },
    checkpoints        = {
      { col = 34, row = 2,  w = 4, h = 4 },
      { col = 2,  row = 16, w = 4, h = 4 },
      { col = 2,  row = 2,  w = 4, h = 4 },
      { col = 34, row = 16, w = 4, h = 4 },
      { col = 18, row = 9,  w = 4, h = 4 }
    },
    coins              = {
      { col = 36, row = 12 },
      { col = 10, row = 18 },
      { col = 24, row = 16 },
      { col = 4,  row = 11 },
      { col = 10, row = 7 },
    },
    base_coins         = 4,
    ranks              = { C = 66.0, B = 85.0, A = 90.0, S = 113.0 },
    label              = "Track 4",
    pay                = 135,
    unlock_cost        = 10000,
    -- Unlocking needs an S rank on every earlier track instead of the usual
    -- rank A on the previous one (see economy.track_unlock_ready).
    unlock_needs_all_s = true,
    shop               = {
      {
        kind      = "checkpoints",
        label     = "Checkpoint",
        currency  = "cash",
        base_cost = 10000,
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
        base_cost = 10000,
        growth    = 1.3
      },
      {
        kind          = "nirvana",
        label         = "Nirvana",
        currency      = "cash",
        max           = 1,
        base_cost     = 0,
        growth        = 1,
        requires_rank = "S"
      }
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

M.TRACK_ORDER           = { "track1", "basic", "track2", "track4" }

-- Loop 1 is a pure-racing prologue: only the first three tracks exist, and
-- Track 4 (along with ghosts, coins, and the idle economy) is hidden until
-- loop 2. A prefix of TRACK_ORDER, so get_track_index works for both.
local LOOP1_TRACK_ORDER = { "track1", "basic", "track2" }

function M.track_order(loop)
  return loop == 1 and LOOP1_TRACK_ORDER or M.TRACK_ORDER
end

-- Track fields below prefer the track's `loop1` override table during the
-- loop-1 prologue. A nil loop always reads the base field.

function M.shop(id, loop)
  local tdata = M.TRACKS[id]
  return loop == 1 and tdata.loop1 and tdata.loop1.shop or tdata.shop
end

function M.ranks(id, loop)
  local tdata = M.TRACKS[id]
  return loop == 1 and tdata.loop1 and tdata.loop1.ranks or tdata.ranks
end

function M.unlock_cost(id, loop)
  local tdata = M.TRACKS[id]
  if loop == 1 and tdata.loop1 and tdata.loop1.unlock_cost ~= nil then
    return tdata.loop1.unlock_cost
  end
  return tdata.unlock_cost
end

-- Rank needed on the previous track to unlock the next one: B during the
-- loop-1 prologue, A afterwards.
function M.unlock_rank(loop)
  return loop == 1 and "B" or "A"
end

function M.track_shop_item(track_id, kind, loop)
  for _, item in ipairs(M.shop(track_id, loop)) do
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

function M.get_track_index(id)
  for i, tid in ipairs(M.TRACK_ORDER) do
    if tid == id then return i end
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

-- Coins active for free from the start: one per Head Start (start_coins)
-- skill rank, capped at what the track can hold this loop.
function M.start_coin_floor(id, loop, start_coins)
  return math.min(start_coins or 0, M.max_coins(id, loop))
end

-- Highest total coin count reachable on a track this loop: no coins at all
-- in the loop-1 prologue, the original set in loop 2, both sets in loop 3+.
function M.max_coins(id, loop)
  loop = loop or 1
  if loop == 1 then return 0 end
  return loop >= 3 and #M.TRACKS[id].coins or M.TRACKS[id].base_coins
end

function M.default_track_state(id, loop, start_coins)
  return {
    ghost_line  = nil,
    best_rate   = nil,
    ghosts      = 0,
    coins       = M.start_coin_floor(id, loop, start_coins),
    checkpoints = 1,
  }
end

return M
