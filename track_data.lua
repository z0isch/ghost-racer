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

-- Loop-1 prologue variant: checkpoint-only economy, so prices are scaled way
-- down, and no magnet (coins don't exist until loop 2).
local LOOP1_UPGRADES = {
  {
    kind      = "accel",
    label     = "Acceleration",
    max       = 4,
    base_cost = 5,
    growth    = 1.45
  },
  {
    kind      = "drift",
    label     = "Drift",
    max       = 1,
    base_cost = 60,
    growth    = 1.6
  },
  {
    kind      = "drift_boost",
    label     = "Drift Boost",
    max       = 1,
    base_cost = 80,
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
    ranks       = { C = 1.0, B = 2.15, A = 2.65, S = 4 },
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
        base_cost = 18,
        growth    = 1.6
      },
    },
    -- Loop-1 prologue overrides: checkpoint-only income (no ghosts, no
    -- coins - the shop is empty and car upgrades live in the global
    -- UPGRADES column), so ranks are scaled way down. Values are
    -- provisional - tune freely.
    loop1       = {
      ranks = { C = .8, B = 1.1, A = 1.5, S = 3 },
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
    ranks       = { C = 5.0, B = 6.5, A = 8.4, S = 11.0 },
    label       = "Track 2",
    pay         = 15,
    unlock_cost = 250,
    shop        = {
      {
        kind      = "checkpoints",
        label     = "Checkpoint",
        currency  = "cash",
        base_cost = 300,
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
    -- Loop-1 prologue overrides - provisional, tune freely.
    loop1       = {
      unlock_cost = 28,
      ranks       = { C = 2.5, B = 2.7, A = 3, S = 6.0 },
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
    base_coins  = 4,
    ranks       = { C = 12.0, B = 18.0, A = 25.0, S = 31.0 },
    label       = "Track 3",
    pay         = 45,
    unlock_cost = 2000,
    shop        = {
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
    -- Loop-1 prologue overrides - provisional, tune freely. Nirvana lives
    -- here in loop 1 (Track 4 doesn't exist yet) and needs rank A on every
    -- prologue track instead of S on this one.
    loop1       = {
      unlock_cost = 200,
      ranks       = { C = 5, B = 8, A = 10.5, S = 20.0 },
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
          label             = "Nirvana?",
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
    ranks              = { C = 30.0, B = 60.0, A = 90.0, S = 98.0 },
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
      {
        kind          = "nirvana",
        label         = "Nirvana?",
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

-- Loop-completion rank: seconds of loop time a finished loop must come in
-- under to earn each letter. Tuning knobs only - change freely.
local LOOP_RANK_TIMES = { S = 90, A = 240, B = 300, C = 600 }
local LOOP_RANK_ORDER = { "S", "A", "B", "C" }

-- Rank a loop time is pacing toward right now: what finishing at `seconds`
-- would rate, before the loop-1 pin below. The buy screen shows this as the
-- provisional rank.
function M.loop_rank_for_time(seconds)
  for _, letter in ipairs(LOOP_RANK_ORDER) do
    if seconds <= LOOP_RANK_TIMES[letter] then return letter end
  end
  return "D"
end

-- Buy-screen tachometer: maps a live loop time onto a 0..1 needle position
-- and the rank it lands in. The dial is five equal wedges (S at the 0 end
-- through D at 1), and the needle climbs across a wedge as its time thresholds
-- pass -- the same zone-and-needle scheme as the race HUD's rank bar, wrapped
-- onto an arc. Past the C threshold the needle sinks through the D wedge over
-- another C-length span, then pins at the redline.
function M.loop_rank_gauge(seconds)
  local prev_t = 0
  for i, letter in ipairs(LOOP_RANK_ORDER) do -- S, A, B, C
    local t1 = LOOP_RANK_TIMES[letter]
    if seconds <= t1 then
      local p = (seconds - prev_t) / (t1 - prev_t)
      return (i - 1) * 0.2 + 0.2 * p, letter
    end
    prev_t = t1
  end
  local p = math.min((seconds - prev_t) / prev_t, 1)
  return 0.8 + 0.2 * p, "D"
end

-- Rank actually awarded for finishing a loop in `seconds`. Loop 1 is the
-- scripted prologue and always rates D, no matter how fast it goes.
function M.loop_rank(loop, seconds)
  if loop == 1 then return "D" end
  return M.loop_rank_for_time(seconds)
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

-- Coins the shop will sell on a track this loop: none in the loop-1
-- prologue, base_coins afterwards. Head Start freebies never change this -
-- they sit on top of the buyable set, not inside it.
function M.buyable_coins(id, loop)
  loop = loop or 1
  if loop == 1 then return 0 end
  return M.TRACKS[id].base_coins
end

-- Coins active for free from the start: one per Head Start (start_coins)
-- skill rank, filling only the authored slots left over after the buyable
-- set so buying the full base_coins is always possible.
function M.start_coin_floor(id, loop, start_coins)
  local spare = M.max_coins(id, loop) - M.buyable_coins(id, loop)
  return math.max(0, math.min(start_coins or 0, spare))
end

-- Highest total coin count reachable on a track this loop: no coins at all
-- in the loop-1 prologue, the base set in loop 2, the full authored list in
-- loop 3+ (the slots beyond base_coins are reachable only via Head Start).
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
