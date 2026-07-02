local ghost                = require "ghost"
local track_data           = require "track_data"
local popups               = require "popups"
local car                  = require "car"
local persist              = require "persist"

local CHECKPOINT_PAY       = 5
local GHOST_CHECKPOINT_PAY = 1
local COIN_PAY             = 5

-- Rank multipliers, tuning knobs only - change freely.
local RANK_MULTS           = { D = 1.0, C = 1.5, B = 2.0, A = 3.0, S = 5.0 }
-- Ascending order of ranks above the D floor, checked against track_data.TRACKS[id].ranks.
local RANK_LETTERS         = { "C", "B", "A", "S" }

local M                    = {}

M.COIN_PAY                 = COIN_PAY
M.CHECKPOINT_PAY           = CHECKPOINT_PAY
M.RANK_MULTS               = RANK_MULTS

function M.owns_any_ghost()
  for _, tstate in pairs(State.tracks) do
    if tstate.ghosts and tstate.ghosts >= 1 then return true end
  end
  return false
end

-- Rank earned by a $/sec rate on a given track. Below the lowest threshold is "D".
function M.rank_for_rate(id, rate)
  local thresholds = track_data.TRACKS[id].ranks
  local rank       = "D"
  if rate and rate > 0 then
    for _, letter in ipairs(RANK_LETTERS) do
      if rate >= thresholds[letter] then rank = letter end
    end
  end
  return rank
end

function M.rank_mult(id, rate)
  return RANK_MULTS[M.rank_for_rate(id, rate)]
end

-- Rank of the promoted lap currently stored for a track.
function M.track_rank(id)
  local tstate = State.tracks[id]
  return M.rank_for_rate(id, tstate and tstate.cash_per_sec)
end

function M.track_cash_rate(id)
  local tstate = State.tracks[id]
  if not tstate or not tstate.ghost_line then return 0 end
  local period = ghost.loop_period(tstate.ghost_line)
  if period <= 0 then return 0 end
  local tdata   = track_data.TRACKS[id]
  local pickups = ghost.get_track_sim(id).ghost_coin_pickups
  local count   = #tdata.checkpoints + (pickups and #pickups or 0)
  return tstate.ghosts
      * (count * GHOST_CHECKPOINT_PAY / period)
      * M.rank_mult(id, tstate.cash_per_sec)
end

function M.ghost_cash_rate()
  local total = 0
  for id, v in pairs(State.unlocked) do
    if v and State.tracks[id] then total = total + M.track_cash_rate(id) end
  end
  return total
end

function M.lap_cash_rate(line)
  local period = ghost.loop_period(line)
  if period <= 0 then return 0 end
  local tdata   = track_data.TRACKS[State.active_track]
  local tstate  = State.tracks[State.active_track]
  local pickups = ghost.compute_coin_pickups(line, tdata.coins, tstate.coins)
  local count   = #tdata.checkpoints + (pickups and #pickups or 0)
  return count * GHOST_CHECKPOINT_PAY / period
end

function M.upgrade_cost(kind)
  local id = State.active_track
  local u  = track_data.track_shop_item(id, kind)
  if not u then return nil end
  local lvl
  if kind == "ghosts" or kind == "coins" then
    lvl = State.tracks[id][kind]
  else
    lvl = State[kind]
  end
  local max = u.max
  if kind == "coins" then max = #track_data.TRACKS[id].coins end
  if lvl >= max then return nil end
  return math.floor(u.base_cost * (u.growth ^ lvl))
end

function M.try_buy(kind)
  local id   = State.active_track
  local cost = M.upgrade_cost(kind)
  if cost == nil then return end
  if kind == "ghosts" and not State.tracks[id].ghost_line then return end
  if cost > 0 and State.money < cost then return end
  State.money = State.money - cost
  if kind == "ghosts" or kind == "coins" then
    local was_first_ghost = kind == "ghosts" and State.tracks[id][kind] == 0
    State.tracks[id][kind] = State.tracks[id][kind] + 1
    if was_first_ghost then
      ghost.restart_schedule(id)
    elseif kind == "ghosts" then
      ghost.reset_track_phases(id)
    end
    if kind == "coins" then ghost.rebuild_sim(id) end
  else
    State[kind] = State[kind] + 1
  end
  car.apply_upgrades(State.accel, State.top_speed)
  persist.save()
end

function M.try_unlock_track(id)
  local cost = track_data.TRACKS[id].unlock_cost
  if not cost or State.money < cost then return end
  State.money        = State.money - cost
  State.unlocked[id] = true
  if not State.tracks[id] then
    State.tracks[id] = track_data.default_track_state()
  end
  ghost.rebuild_sim(id)
  persist.save()
  return true
end

function M.bank(event)
  local id     = event.track_id
  local tstate = State.tracks[id]
  local mult   = M.rank_mult(id, tstate.cash_per_sec)
  local pay    = GHOST_CHECKPOINT_PAY * mult
  State.money  = State.money + pay
  if id == State.active_track then
    popups.spawn({
      amount    = pay,
      x         = event.x,
      y         = event.y,
      ghost     = true,
      alpha_mul = State.mode == "race" and 0.1 or 1,
    })
  end
end

return M
