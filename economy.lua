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
-- Ascending order of ranks above the D floor, checked against track_data.ranks(id, loop).
local RANK_LETTERS = { "C", "B", "A", "S" }
local RANK_ORDER   = { D = 0, C = 1, B = 2, A = 3, S = 4 }

local M            = {}

M.RANK_MULTS       = RANK_MULTS

-- $ awarded per checkpoint/coin on a given track.
function M.track_pay(id)
  return track_data.TRACKS[id].pay
end

-- Owned checkpoint count on a track, clamped to what exists.
function M.owned_cps(id)
  local tstate = State.tracks[id]
  local total  = #track_data.TRACKS[id].checkpoints
  return math.min(tstate and tstate.checkpoints or 1, total)
end

-- Fraction of the course owned; scales every measured rate before ranking.
function M.cp_fraction(id)
  return M.owned_cps(id) / #track_data.TRACKS[id].checkpoints
end

-- $ paid per checkpoint/coin at a given rank mult, scaled by mult over the D
-- floor so D rank keeps base pay and each rank above it multiplies it (with
-- the current RANK_MULTS: C 2x, B 3x, A 5x, S 10x) - a constant 1/RANK_MULTS.D
-- ratio over the ghost payout at every rank. Rounded to a whole dollar since
-- floating point mults (0.4, 0.6, ...) don't always divide to an exact
-- integer and every "$%d" display of this value would break.
function M.pay_for_mult(id, mult)
  return math.floor(M.track_pay(id) * (mult / RANK_MULTS.D) + 0.5)
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
  local thresholds = track_data.ranks(id, State.loop)
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
  local owned     = M.owned_cps(id)
  local remaining = owned - race.next_checkpoint + 1
  local earned    = race.raw_earned + remaining * M.track_pay(id)
  local raw       = race.time > 0 and (earned / race.time) or math.huge
  return raw * M.cp_fraction(id)
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

-- True once a track's established rank is at or above `letter`.
function M.rank_at_least(id, letter)
  return RANK_ORDER[M.track_rank(id)] >= RANK_ORDER[letter]
end

-- True when a shop item's rank gate is met: `requires_rank` checks the given
-- track (e.g. Nirvana needing rank S on Track 4), `requires_rank_all` checks
-- every track in this loop (e.g. loop-1 Nirvana needing rank A everywhere).
-- Ungated items always pass.
function M.shop_item_unlocked(id, item)
  if item.requires_rank_all then
    for _, tid in ipairs(track_data.track_order(State.loop)) do
      if not M.rank_at_least(tid, item.requires_rank_all) then return false end
    end
    return true
  end
  if not item.requires_rank then return true end
  return M.rank_at_least(id, item.requires_rank)
end

-- True when the rank requirement to unlock a track is met: the loop's unlock
-- rank (B in the loop-1 prologue, A afterwards) on the previous track
-- normally, or an S rank on every earlier track when the track sets
-- `unlock_needs_all_s`.
function M.track_unlock_ready(id)
  local idx = track_data.get_track_index(id)
  if track_data.TRACKS[id].unlock_needs_all_s then
    for i = 1, idx - 1 do
      if M.track_rank(track_data.TRACK_ORDER[i]) ~= "S" then return false end
    end
    return true
  end
  return M.rank_at_least(track_data.TRACK_ORDER[idx - 1], track_data.unlock_rank(State.loop))
end

-- Track whose shop sells Nirvana this loop (Track 3 during the loop-1
-- prologue, Track 4 afterwards), or nil.
function M.nirvana_track()
  for _, tid in ipairs(track_data.track_order(State.loop)) do
    if track_data.track_shop_item(tid, "nirvana", State.loop) then return tid end
  end
  return nil
end

-- True once Nirvana's rank gate is met on the track that sells it.
function M.nirvana_ready()
  local tid = M.nirvana_track()
  return tid ~= nil and M.shop_item_unlocked(tid, track_data.track_shop_item(tid, "nirvana", State.loop))
end

-- First track in this loop's track order the player hasn't unlocked yet, or
-- nil. Track 4 doesn't exist in loop 1, so it's never offered there.
function M.next_locked_track()
  for _, tid in ipairs(track_data.track_order(State.loop)) do
    if not State.unlocked[tid] then return tid end
  end
  return nil
end

-- $/sec earned from ghosts before the rank multiplier is applied.
function M.track_raw_cash_rate(id)
  local tstate = State.tracks[id]
  if not tstate or not tstate.ghost_line then return 0 end
  local period = ghost.loop_period(tstate.ghost_line)
  if period <= 0 then return 0 end
  local tdata   = track_data.TRACKS[id]
  local pickups = ghost.get_track_sim(id).ghost_coin_pickups
  local pay     = (ghost.crossed_cp_count(id) + (pickups and #pickups or 0)) * tdata.pay
  return tstate.ghosts * (pay / period) * ghost.SPEED_MULT
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
  local tdata     = track_data.TRACKS[State.active_track]
  local tstate    = State.tracks[State.active_track]
  local radius    = track_data.magnet_radius(State.magnet)
  local pickups   = ghost.compute_coin_pickups(line, tdata.coins, tstate.coins, radius)
  local crossings = ghost.compute_cp_crossings(line, tdata.checkpoints)
  local pay       = (#crossings + (pickups and #pickups or 0)) * tdata.pay
  return pay / period
end

-- Shop item definition for `kind` in the current context: global car
-- upgrades first (track-independent), then the active track's shop
-- (ghosts/coins/nirvana).
function M.shop_item(kind)
  return track_data.upgrade_item(kind, State.loop)
      or track_data.track_shop_item(State.active_track, kind, State.loop)
end

function M.upgrade_cost(kind)
  local id = State.active_track
  local u  = M.shop_item(kind)
  if not u then return nil end
  if kind == "coins" then
    local free = track_data.free_coins(id, State.loop)
    if State.tracks[id].coins >= track_data.max_coins(id, State.loop) then return nil end
    return math.floor(u.base_cost * (u.growth ^ (State.tracks[id].coins - free)))
  end
  if kind == "checkpoints" then
    local owned = State.tracks[id].checkpoints
    if owned >= #track_data.TRACKS[id].checkpoints then return nil end
    return math.floor(u.base_cost * (u.growth ^ (owned - 1)))
  end
  local lvl
  if kind == "ghosts" then
    lvl = State.tracks[id][kind]
  else
    lvl = State[kind]
  end
  if lvl >= u.max then return nil end
  return math.floor(u.base_cost * (u.growth ^ lvl))
end

-- Kinds that show a one-time explainer modal in the buy scene the first time
-- they're purchased (rank 1 for multi-rank items like `boost`; first-ever
-- across any track for `ghosts` / `coins`, since those counts are per-track).
local FIRST_PURCHASE_MODAL_KINDS = { drift = true, drift_boost = true, boost = true, ghosts = true, coins = true, magnet = true, checkpoints = true }

function M.try_buy(kind)
  local id   = State.active_track
  local cost = M.upgrade_cost(kind)
  if cost == nil then return end
  if not M.shop_item_unlocked(id, M.shop_item(kind)) then return end
  if kind == "ghosts" and not State.tracks[id].ghost_line then return end
  if kind == "drift_boost" and State.drift == 0 then return end
  if cost > 0 and State.money < cost then return end
  State.money = State.money - cost
  if kind == "ghosts" or kind == "coins" or kind == "checkpoints" then
    local was_first_ghost  = kind == "ghosts" and State.tracks[id][kind] == 0
    State.tracks[id][kind] = State.tracks[id][kind] + 1
    if was_first_ghost then
      ghost.restart_schedule(id)
    elseif kind == "ghosts" then
      ghost.reset_track_phases(id)
    end
    if kind == "coins" then ghost.rebuild_sim(id) end
    if FIRST_PURCHASE_MODAL_KINDS[kind] and not State.seen_modals[kind] then
      State.seen_modals[kind] = true
      State.purchase_modal    = kind
    end
  else
    State[kind] = State[kind] + 1
    if FIRST_PURCHASE_MODAL_KINDS[kind] and not State.seen_modals[kind] then
      State.seen_modals[kind] = true
      State.purchase_modal    = kind
    end
    if kind == "magnet" then
      for tid, unlocked in pairs(State.unlocked) do
        if unlocked then ghost.rebuild_sim(tid) end
      end
    end
  end
  if kind == "nirvana" then
    sfx.play("loop_complete")
    persist.start_new_loop()
    return
  end
  car.apply_upgrades(State.car, State.accel, State.top_speed, State.drift >= 1, State.drift_boost >= 1, State.boost)
  persist.save()
end

function M.try_unlock_track(id)
  local cost = track_data.unlock_cost(id, State.loop)
  if not cost or State.money < cost then return end
  if not M.track_unlock_ready(id) then return end
  State.money        = State.money - cost
  State.unlocked[id] = true
  if not State.tracks[id] then
    State.tracks[id] = track_data.default_track_state(id, State.loop)
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
