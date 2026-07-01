local ghost                = require "ghost"
local track_data           = require "track_data"
local popups               = require "popups"
local car                  = require "car"
local persist              = require "persist"

local CHECKPOINT_PAY       = 5
local GHOST_CHECKPOINT_PAY = 1
local COIN_PAY             = 5
local GHOST_COIN_PAY       = 1
local PAR_TIME             = 10.0
local SPEED_MULT_P         = 2

local M                    = {}

M.COIN_PAY                 = COIN_PAY
M.CHECKPOINT_PAY           = CHECKPOINT_PAY
M.COIN_ICON                = "©"

function M.owns_any_ghost()
  for _, tstate in pairs(State.tracks) do
    if tstate.ghosts and tstate.ghosts >= 1 then return true end
  end
  return false
end

function M.speed_mult(t)
  if not t or t <= 0 then return 1.0 end
  return math.max(1.0, (PAR_TIME / t) ^ SPEED_MULT_P)
end

function M.track_cash_rate(id)
  local tstate = State.tracks[id]
  if not tstate or not tstate.ghost_line then return 0 end
  local period = ghost.loop_period(tstate.ghost_line)
  if period <= 0 then return 0 end
  local tdata = track_data.TRACKS[id]
  return tstate.ghosts
      * (#tdata.checkpoints * GHOST_CHECKPOINT_PAY / period)
      * M.speed_mult(tstate.best_time)
end

function M.track_coin_rate(id)
  local tstate = State.tracks[id]
  if not tstate or not tstate.ghost_line then return 0 end
  local period = ghost.loop_period(tstate.ghost_line)
  if period <= 0 then return 0 end
  local pickups = ghost.get_track_sim(id).ghost_coin_pickups
  local count   = pickups and #pickups or 0
  return tstate.ghosts
      * (count * GHOST_COIN_PAY / period)
      * M.speed_mult(tstate.best_time)
end

function M.ghost_cash_rate()
  local total = 0
  for id, v in pairs(State.unlocked) do
    if v and State.tracks[id] then total = total + M.track_cash_rate(id) end
  end
  return total
end

function M.ghost_coin_rate()
  local total = 0
  for id, v in pairs(State.unlocked) do
    if v and State.tracks[id] then total = total + M.track_coin_rate(id) end
  end
  return total
end

function M.lap_cash_rate(line)
  local period = ghost.loop_period(line)
  if period <= 0 then return 0 end
  local tdata = track_data.TRACKS[State.active_track]
  return #tdata.checkpoints * GHOST_CHECKPOINT_PAY / period
end

function M.lap_coin_rate(line)
  local period = ghost.loop_period(line)
  if period <= 0 then return 0 end
  local tdata   = track_data.TRACKS[State.active_track]
  local tstate  = State.tracks[State.active_track]
  local pickups = ghost.compute_coin_pickups(line, tdata.coins, tstate.coins)
  local count   = pickups and #pickups or 0
  return count * GHOST_COIN_PAY / period
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
  local currency = track_data.track_shop_item(id, kind).currency
  local balance  = currency == "coin" and State.coins or State.money
  if cost > 0 and balance < cost then return end
  if currency == "coin" then
    State.coins = State.coins - cost
  else
    State.money = State.money - cost
  end
  if kind == "ghosts" or kind == "coins" then
    State.tracks[id][kind] = State.tracks[id][kind] + 1
    if kind == "ghosts" then ghost.reset_track_phases(id) end
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
    State.tracks[id] = track_data.default_track_state(id)
  end
  ghost.rebuild_sim(id)
  persist.save()
  return true
end

function M.bank(event)
  local id     = event.track_id
  local tstate = State.tracks[id]
  local mult   = M.speed_mult(tstate.best_time)
  local pay, currency
  if event.kind == "checkpoint" then
    pay      = GHOST_CHECKPOINT_PAY * mult
    currency = "cash"
  else
    pay      = GHOST_COIN_PAY * mult
    currency = "coin"
  end
  if currency == "coin" then
    State.coins           = State.coins + pay
    State.coins_collected = true
  else
    State.money = State.money + pay
  end
  if id == State.active_track then
    popups.spawn({
      amount    = pay,
      currency  = currency,
      x         = event.x,
      y         = event.y,
      ghost     = true,
      alpha_mul = State.mode == "race" and 0.1 or 1,
    })
  end
end

return M
