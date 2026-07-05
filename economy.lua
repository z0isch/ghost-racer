local ghost        = require "ghost"
local track_data   = require "track_data"
local popups       = require "popups"
local car          = require "car"
local persist      = require "persist"

-- Rank multipliers, tuning knobs only - change freely.
local RANK_MULTS   = {
  D = 0.2,
  C = 0.4,
  B = 0.6,
  A = 1.0,
  S = 2.0
}
-- Ascending order of ranks above the D floor, checked against track_data.TRACKS[id].ranks.
local RANK_LETTERS = { "C", "B", "A", "S" }

local M            = {}

M.RANK_MULTS       = RANK_MULTS

-- $ awarded per checkpoint/coin on a given track.
function M.track_pay(id)
  return track_data.TRACKS[id].pay
end

-- $ paid per checkpoint/coin at a given rank mult, boosted by 1 + mult above
-- the D floor so D rank keeps base pay and every rank above it earns a bonus
-- on top instead of losing a cut like the ghost payout does. Rounded to a
-- whole dollar since floating point mults (0.4, 0.6, ...) don't always land
-- on an exact integer and every "$%d" display of this value would break.
function M.pay_for_mult(id, mult)
  return math.floor(M.track_pay(id) * (1 + mult - RANK_MULTS.D) + 0.5)
end

-- $ awarded per checkpoint/coin to the player during a live race, based on
-- the track's current established rank.
function M.player_pay(id)
  local tstate = State.tracks[id]
  local mult   = M.rank_mult(id, tstate and tstate.best_rate)
  return M.pay_for_mult(id, mult)
end

-- True if any unlocked track already has at least one of `kind` (a
-- per-track shop item, e.g. "ghosts" or "coins") purchased.
function M.owns_any(kind)
  for _, tstate in pairs(State.tracks) do
    if tstate[kind] and tstate[kind] >= 1 then return true end
  end
  return false
end

function M.owns_any_ghost()
  return M.owns_any("ghosts")
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

-- Live $/sec for the run in progress, as if the remaining checkpoints were
-- crossed right now. Counting the pending payouts makes the HUD rank converge
-- on the result-screen rank instead of trailing a payout behind it.
function M.live_race_rate()
  local race      = State.race
  local id        = State.active_track
  local tdata     = track_data.TRACKS[id]
  local remaining = #tdata.checkpoints - race.next_checkpoint + 1
  local earned    = race.raw_earned + remaining * M.track_pay(id)
  return race.time > 0 and (earned / race.time) or math.huge
end

function M.rank_mult(id, rate)
  return RANK_MULTS[M.rank_for_rate(id, rate)]
end

-- Rank of the best promoted lap stored for a track. Only better laps are
-- promoted (see ghost.promote()), so this never drops.
function M.track_rank(id)
  local tstate = State.tracks[id]
  return M.rank_for_rate(id, tstate and tstate.best_rate)
end

-- True once a track's established rank has ever reached A or S.
function M.a_rank_earned(id)
  local rank = M.track_rank(id)
  return rank == "A" or rank == "S"
end

-- $/sec earned from ghosts before the rank multiplier is applied.
function M.track_raw_cash_rate(id)
  local tstate = State.tracks[id]
  if not tstate or not tstate.ghost_line then return 0 end
  local period = ghost.loop_period(tstate.ghost_line)
  if period <= 0 then return 0 end
  local tdata   = track_data.TRACKS[id]
  local pickups = ghost.get_track_sim(id).ghost_coin_pickups
  local pay     = (#tdata.checkpoints + (pickups and #pickups or 0)) * tdata.pay
  return tstate.ghosts * (pay / period)
end

function M.track_cash_rate(id)
  local tstate = State.tracks[id]
  if not tstate then return 0 end
  return M.track_raw_cash_rate(id) * M.rank_mult(id, tstate.best_rate)
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
  local pay     = (#tdata.checkpoints + (pickups and #pickups or 0)) * tdata.pay
  return pay / period
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

-- Kinds that show a one-time explainer modal in the buy scene the first time
-- they're purchased (rank 1 for multi-rank items like `boost`; first-ever
-- across any track for `ghosts` / `coins`, since those counts are per-track).
local FIRST_PURCHASE_MODAL_KINDS = { drift = true, drift_boost = true, boost = true, ghosts = true, coins = true }

function M.try_buy(kind)
  local id   = State.active_track
  local cost = M.upgrade_cost(kind)
  if cost == nil then return end
  if kind == "ghosts" and not State.tracks[id].ghost_line then return end
  if kind == "drift_boost" and State.drift == 0 then return end
  if cost > 0 and State.money < cost then return end
  State.money = State.money - cost
  if kind == "ghosts" or kind == "coins" then
    local was_first_ghost  = kind == "ghosts" and State.tracks[id][kind] == 0
    local was_first_ever   = FIRST_PURCHASE_MODAL_KINDS[kind] and not M.owns_any(kind)
    State.tracks[id][kind] = State.tracks[id][kind] + 1
    if was_first_ghost then
      ghost.restart_schedule(id)
    elseif kind == "ghosts" then
      ghost.reset_track_phases(id)
    end
    if kind == "coins" then ghost.rebuild_sim(id) end
    if was_first_ever then
      State.purchase_modal = kind
    end
  else
    local was_zero = State[kind] == 0
    State[kind] = State[kind] + 1
    if was_zero and FIRST_PURCHASE_MODAL_KINDS[kind] then
      State.purchase_modal = kind
    end
  end
  car.apply_upgrades(State.accel, State.top_speed, State.drift >= 1, State.drift_boost >= 1, State.boost)
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
  local mult   = M.rank_mult(id, tstate.best_rate)
  local pay    = M.track_pay(id) * mult
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
