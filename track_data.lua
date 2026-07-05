local basic_map = require "tile-map.basic"
local track1    = require "tile-map.track1"
local track2    = require "tile-map.track2"

local M         = {}

M.tile_size     = track1.tilewidth

M.TRACKS        = {
  track1 = {
    map         = track1,
    spawn       = { col = 5, row = 14 },
    checkpoints = {
      { col = 31, row = 8, w = 4, h = 7 },
    },
    coins       = {
      { col = 18, row = 8 },
    },
    ranks       = { C = 1.0, B = 2.15, A = 2.75, S = 5.0 },
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
        base_cost = 30,
        growth    = 1.6
      },
      {
        kind      = "accel",
        label     = "Acceleration",
        currency  = "cash",
        max       = 4,
        base_cost = 25,
        growth    = 1.6
      },
    },
  },
  basic = {
    map         = basic_map,
    spawn       = { col = 1, row = 9 },
    checkpoints = {
      { col = 35, row = 6, w = 4, h = 11 },
      { col = 1,  row = 6, w = 4, h = 11 },
    },
    coins       = {
      { col = 18, row = 7 },
      { col = 34, row = 12 },
      { col = 10, row = 16 },
    },
    ranks       = { C = 10.0, B = 14.0, A = 16.0, S = 35.0 },
    label       = "Track 2",
    pay         = 15,
    unlock_cost = 250,
    shop        = {
      {
        kind      = "ghosts",
        label     = "Ghost",
        currency  = "cash",
        max       = 8,
        base_cost = 150,
        growth    = 1.6
      },
      {
        kind      = "coins",
        label     = "Coin",
        currency  = "cash",
        base_cost = 600,
        growth    = 1.6
      },
      {
        kind      = "drift",
        label     = "Drift",
        currency  = "cash",
        max       = 1,
        base_cost = 1800,
        growth    = 1.6
      },
      {
        kind      = "drift_boost",
        label     = "Drift Boost",
        currency  = "cash",
        max       = 1,
        base_cost = 2000,
        growth    = 1.6
      },
    },
  },
  track2 = {
    map         = track2,
    spawn       = { col = 7, row = 3 },
    checkpoints = {
      { col = 34, row = 6,  w = 5, h = 4 },
      { col = 10, row = 14, w = 7, h = 2 },
      { col = 1,  row = 1,  w = 5, h = 5 },
    },
    coins       = {
      { col = 18, row = 7 },
      { col = 34, row = 12 },
      { col = 10, row = 16 },
    },
    ranks       = { C = 1.2, B = 1.8, A = 2.5, S = 3.5 },
    label       = "Track 3",
    pay         = 5,
    unlock_cost = 500,
    shop        = {
      {
        kind      = "ghosts",
        label     = "Ghost",
        currency  = "cash",
        max       = 8,
        base_cost = 75,
        growth    = 1.55
      },
      {
        kind      = "coins",
        label     = "Coin",
        currency  = "cash",
        base_cost = 120,
        growth    = 1.6
      },
      {
        kind      = "boost",
        label     = "Boost",
        currency  = "cash",
        max       = 5,
        base_cost = 200,
        growth    = 1.6
      },
    },
  },
}

M.TRACK_ORDER   = { "track1", "basic", "track2" }

function M.track_shop_item(track_id, kind)
  for _, item in ipairs(M.TRACKS[track_id].shop) do
    if item.kind == kind then return item end
  end
  return nil
end

function M.kind_max(kind)
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

function M.default_track_state()
  return {
    ghost_line    = nil,
    best_time     = nil,
    best_earned   = nil,
    cash_per_sec  = nil,
    ghosts        = 0,
    coins         = 0,
    a_rank_earned = false,
  }
end

return M
