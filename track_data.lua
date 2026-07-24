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
-- down, and no magnet (nothing to magnetize - coins arrive with the Loose
-- Change skill node, which needs 2 finished loops). The magnet row is hidden
-- in later coinless loops too - see scenes/buy.lua.
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
    -- bought): checkpoint-and-ghost income only, so scaled way down. Covers
    -- the whole loop-1 prologue plus every later loop before the node lands.
    -- Provisional - tune freely.
    no_coin_ranks = { C = .8, B = 1.1, A = 1.5, S = 3 },
    label         = "Track 1",
    pay           = 5,
    unlock_cost   = nil,
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
    -- Loop-1 prologue overrides: checkpoint-only income (no ghosts, no
    -- coins - the shop is empty and car upgrades live in the global
    -- UPGRADES column).
    loop1         = {
      shop = {},
    },
  },
  basic = {
    map           = basic_map,
    spawn         = { col = 1, row = 9 },
    checkpoints   = {
      { col = 33, row = 12, w = 2, h = 5 },
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
    unlock_cost   = 250,
    shop          = {
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
    loop1         = {
      unlock_cost = 28,
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
    map           = track2,
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
    unlock_cost   = 2000,
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
    -- Loop-1 prologue overrides - provisional, tune freely. Nirvana lives
    -- here in loop 1 (Track 4 doesn't exist yet) and needs rank A on every
    -- prologue track instead of S on this one.
    loop1         = {
      unlock_cost = 200,
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
    ranks              = { C = 30.0, B = 60.0, A = 80.0, S = 89.0 },
    -- Track 4 never existed in the loop-1 prologue, so it had no coinless
    -- thresholds until now: coins used to arrive with loop 2, ahead of this
    -- track. They're behind a skill node now, so this track can be raced
    -- coinless. Scaled off `ranks` at roughly the ratio the other tracks use
    -- (~0.43 up to A, ~0.74 at S) - pure guesses, tune in playtest.
    no_coin_ranks      = { C = 13.0, B = 26.0, A = 34.0, S = 66.0 },
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
-- loop-1 prologue. A nil loop always reads the base field. Rank thresholds
-- used to live here too; they key off coin availability now (see M.ranks).

function M.shop(id, loop)
  local tdata = M.TRACKS[id]
  return loop == 1 and tdata.loop1 and tdata.loop1.shop or tdata.shop
end

-- Rank thresholds for a track. Keyed on whether coins are unlocked (the
-- Loose Change skill node - see persist.rederive_skill_effects), not on the
-- loop: a coinless track pays checkpoints and ghosts only, whether that's the
-- loop-1 prologue or a loop 2+ save that hasn't bought the node yet.
function M.ranks(id, has_coins)
  local tdata = M.TRACKS[id]
  return has_coins and tdata.ranks or tdata.no_coin_ranks
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

-- Per-course rank as a number for loop scoring: linear (every rank-up worth
-- the same) with a positive D floor so even a D course still contributes -- a
-- freshly unlocked, still-D track adds time to the loop but shouldn't be pure
-- dead weight. Deliberately NOT reused from economy.RANK_MULTS: the pay
-- multipliers are a separate concern, and coupling them would let a payout
-- retune silently shift loop rank. Extend with S+/S++ (=6, =7, ...) when the
-- manual-rank rework lands.
local LOOP_RANK_POINTS = { D = 1, C = 2, B = 3, A = 4, S = 5 }

-- Ascending per-course rank letters above the D floor, checked against
-- M.ranks(id, has_coins). Shared by rank_for_rate; economy.rank_for_rate
-- delegates here so there's a single source.
local RANK_LETTERS = { "C", "B", "A", "S" }

-- Rank earned by a $/sec `rate` on a track, against the coinless or full
-- thresholds per `has_coins`. Below the lowest threshold is "D". Pure (no
-- State), so loop scoring can reach it from track_data without pulling in
-- economy (economy requires persist, which requires track_data - a cycle).
-- economy.rank_for_rate delegates here.
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

-- Ordered per-course ranks over this loop's track order, reading each track's
-- best_rate from `tracks`. Feeds both loop_points (summed) and the end-of-loop
-- breakdown modal (shown line by line).
--
-- `raced` distinguishes a course you haven't reached yet from one you raced
-- badly - best_rate is nil until a lap is promoted (see ghost.promote) and
-- resets with the loop, so both otherwise report "D". loop_points banks only
-- raced courses, which is what lets the live tach climb instead of starting
-- pinned at S. By loop end every course is raced, so nothing downstream of a
-- finished loop sees a difference.
function M.loop_course_ranks(loop, tracks, has_coins)
  local out = {}
  for _, id in ipairs(M.track_order(loop)) do
    local ts   = tracks[id]
    local rate = ts and ts.best_rate
    out[#out + 1] = {
      id    = id,
      rank  = M.rank_for_rate(id, rate, has_coins),
      raced = rate ~= nil,
    }
  end
  return out
end

-- Loop score: total per-course rank points banked divided by the average time
-- per banked course (loop_time / n) -- equivalently n * Σrank / loop_time. So
-- at a fixed average pace more courses banked scores higher (mastering more
-- content is a bigger achievement), and at a fixed course count a faster loop
-- scores higher.
--
-- `n` counts courses actually raced, not the whole roster, and unraced courses
-- contribute nothing. Mid-loop that makes this a score of the loop *so far*
-- rather than a projection off a near-zero clock: the tach starts at the
-- redline (nothing banked) and steps up each time a course lands, instead of
-- opening pinned at S and only ever sinking. A partial loop scoring low is the
-- same N-reward term doing its job - a partial loop is a smaller roster.
--
-- At loop completion n == #track_order and every rank is real, so a finished
-- loop scores exactly what it always did. Guards loop_time <= 0 to 0.
function M.loop_points(loop, tracks, loop_time, has_coins)
  if not loop_time or loop_time <= 0 then return 0 end
  local sum, n = 0, 0
  for _, entry in ipairs(M.loop_course_ranks(loop, tracks, has_coins)) do
    if entry.raced then
      sum = sum + LOOP_RANK_POINTS[entry.rank]
      n   = n + 1
    end
  end
  return n * sum / loop_time
end

-- Loop-completion thresholds on loop_points (higher = better). Calibrated
-- against the current 4-track roster: an all-A loop (Σrank 16) at ~240s scores
-- 4*16/240 ~= 0.27, landing at the A/B edge to preserve today's difficulty
-- feel. Because loop_points scales with track count, these fixed thresholds
-- mean grades inflate as the roster grows -- intended (a bigger game is a
-- bigger achievement), so retune as tracks and S+/S++ ranks are added. Tuning
-- knobs only - change freely (empirical, tune in playtest).
local LOOP_RANK_POINT_THRESHOLDS = { S = 0.40, A = 0.26, B = 0.15, C = 0.07 }
local LOOP_RANK_POINT_ORDER      = { "S", "A", "B", "C" }

-- Letter a loop_points value earns. Below the C threshold is "D". A typical
-- slow loop 1 (3 tracks, mostly low ranks, lots of learning/modal time) lands
-- here in D as an emergent result of the formula rather than a hard pin.
function M.loop_rank_for_points(points)
  for _, letter in ipairs(LOOP_RANK_POINT_ORDER) do
    if points >= LOOP_RANK_POINT_THRESHOLDS[letter] then return letter end
  end
  return "D"
end

-- Buy-screen tachometer, reading loop_points (higher = better) instead of
-- elapsed seconds: the needle points at the S end (f=0) for a high score and
-- sinks toward the redline D (f=1) as the score drops. The dial is still five
-- equal wedges (S at the 0 end through D at 1) and the needle climbs across a
-- wedge as its point thresholds pass -- the same zone-and-needle scheme as the
-- race HUD's rank bar, wrapped onto an arc. This flips the old axis, so the
-- needle now moves BOTH ways: it sinks as the clock ticks (points fall) and
-- jumps up when a course promotes (points rise), making the two levers visible.
-- Above the S threshold the needle climbs through the S wedge over another
-- S-threshold span, then pins at f=0; below C it sinks through the D wedge and
-- pins at the redline.
function M.loop_rank_gauge(points)
  local s_hi = LOOP_RANK_POINT_THRESHOLDS.S
  if points >= s_hi then
    local p = math.min((points - s_hi) / s_hi, 1)
    return 0.2 - 0.2 * p, "S"
  end
  local hi = s_hi
  for i = 2, #LOOP_RANK_POINT_ORDER do -- A, B, C (wedge indices 2..4)
    local letter = LOOP_RANK_POINT_ORDER[i]
    local lo     = LOOP_RANK_POINT_THRESHOLDS[letter]
    if points >= lo then
      local p = (points - lo) / (hi - lo)
      return i * 0.2 - 0.2 * p, letter
    end
    hi = lo
  end
  local c = LOOP_RANK_POINT_THRESHOLDS.C
  local p = math.min((c - points) / c, 1)
  return 0.8 + 0.2 * p, "D"
end

-- Rank actually awarded for finishing a loop: the letter its loop_points earn,
-- for every loop including loop 1 (the score is honest now - no special case).
function M.loop_rank(loop, tracks, loop_time, has_coins)
  return M.loop_rank_for_points(M.loop_points(loop, tracks, loop_time, has_coins))
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
    ghosts      = 0,
    coins       = M.start_coin_floor(id, has_coins, start_coins),
    checkpoints = 1,
  }
end

return M
