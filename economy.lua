local ghost              = require "ghost"
local track_data         = require "track_data"
local popups             = require "popups"
local car                = require "car"
local persist            = require "persist"
local reference          = require "reference"

-- Rank multipliers, tuning knobs only - change freely.
local RANK_MULTS         = {
  D = 0.2,
  C = 0.4,
  B = 0.6,
  A = 1.0,
  S = 2.0
}
local RANK_ORDER         = { D = 0, C = 1, B = 2, A = 3, S = 4 }

-- ¥ a track is worth this loop at each best-race rank, the cross-loop payout
-- that rank now drives (rank is already the in-loop cash multiplier; this
-- makes it the skill-tree currency too). Absolute totals, so a track that
-- climbs from C to A banks the gap and ends the loop worth RANK_YEN[A]. D pays
-- nothing - a track you only limped through doesn't fund the climb. Tuning
-- knobs only (Q15's D->0, C->x, B->y, A->z, S->w) - change freely.
local RANK_YEN           = { D = 0, C = 15, B = 30, A = 60, S = 120 }

-- The current-speed estimate of remaining time is padded by this factor so the
-- meter leans conservative: better to under-promise and let the player beat the
-- bar than to promise a rank and rob it at the finish.
local FINISH_FUDGE       = 1.08

local M                  = {}

M.RANK_MULTS             = RANK_MULTS
M.RANK_YEN               = RANK_YEN

function M.rank_yen(rank)
  return RANK_YEN[rank] or 0
end

-- Total ¥ this loop's race ranks are worth across the corridor - what a Rebirth
-- carries into the garage. Sums each raced track's rank ¥; equals what's been
-- banked into the skill tree this loop (bank_race_yen credits the same amounts
-- incrementally).
function M.loop_yen_total()
  local total = 0
  for _, id in ipairs(track_data.track_order()) do
    local ts = State.tracks[id]
    if ts and ts.best_rate then total = total + RANK_YEN[M.track_rank(id)] end
  end
  return total
end

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

-- Rank earned by a $/sec rate on a track, against the coinless or full
-- thresholds depending on whether coins are unlocked. Below the lowest
-- threshold is "D". Delegates to track_data (the single source), so loop
-- scoring and live ranking share one implementation.
function M.rank_for_rate(id, rate)
  return track_data.rank_for_rate(id, rate, State.coins_unlocked)
end

-- Projected finish $/sec for the run in progress: money already earned plus
-- every owned-but-uncrossed checkpoint's pay (all of them are guaranteed --
-- the race only ends once each has been crossed in order -- so they're priced
-- in for the whole race rather than at the crossing; race.lua mutes their
-- collect-juice to match, so no pop fires there), divided by the projected
-- time to reach the owned finish. That time is projected against the
-- reference's pace shape: t_ref is the reference's own time to reach the car's
-- current arc position, so time/t_ref is the run's pace ratio versus the
-- reference, and the remaining reference time scaled by that ratio is the time
-- left. This reads s_live's *position* (via t_ref) rather than its time
-- derivative, so an off-line projection wobble nudges the estimate instead of
-- spiking it -- the earlier arc-speed model differentiated s_live and took a
-- min against the average, which turned every off-line stall into a sharp dip.
-- Padded by FINISH_FUDGE (on the remaining term only, so it vanishes at the
-- finish) so it leans conservative: the bar rises toward the true finish rank
-- rather than peeking a rank high and dropping at the line. Coins aren't
-- guaranteed, so raw_earned still jumps the instant one is collected while
-- proj_time moves smoothly -- that's the only remaining source of a pop.
-- Returns nil before there's anything to project from (no reference, no elapsed
-- time, or car not yet mapped onto the line).
function M.projected_rate()
  local race = State.race
  local id   = State.active_track
  if not race or not race.time or race.time <= 0 then return nil end
  local owned     = M.owned_cps(id)
  local s_N, t_N  = reference.owned_finish(owned)
  if not s_N or s_N <= 0 or not t_N or t_N <= 0 then return nil end
  if not race.s_live or race.s_live <= 0 then return nil end
  if not race.t_ref or race.t_ref <= 0 then return nil end

  -- Project the finish time against the reference's pace shape: t_ref is the
  -- reference's own time to reach the car's current arc position, so
  -- time/t_ref is the run's pace ratio versus the reference. The remaining
  -- reference time (t_N - t_ref) scaled by that ratio is the projected time
  -- left; padding only that term by FINISH_FUDGE leans the estimate
  -- conservative while vanishing at the finish (t_ref -> t_N), so the bar
  -- rises into the true rank with no end-of-race snap. No derivative of
  -- s_live is taken, so an off-line projection wobble can't spike the pace.
  local remaining = math.max(0, t_N - race.t_ref)
  local proj_time = race.time + FINISH_FUDGE * race.time * remaining / race.t_ref
  if proj_time <= 0 then return nil end

  local pending_cps = math.max(0, owned - race.next_checkpoint + 1)
  local expected    = race.raw_earned + pending_cps * track_data.TRACKS[id].pay
  return expected * M.cp_fraction(id) / proj_time
end

-- Fraction of the owned course the car has covered, by arc length along the
-- reference line. Drives the meter's warmup (park at D until this crosses a
-- small threshold). 0 with no reference or before the car is mapped on.
function M.race_progress()
  local race = State.race
  if not race or not race.s_live then return 0 end
  local s_N = reference.owned_finish(M.owned_cps(State.active_track))
  if not s_N or s_N <= 0 then return 0 end
  return race.s_live / s_N
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

-- True when a shop item's rank gate is met: `requires_rank_all` checks every
-- track in this loop, `requires_rank` the given track alone. Nothing in the
-- data sets either now (the new Nirvana item is ungated, and it was the last
-- gated shop row), but both are kept as the obvious knobs for re-gating a shop
-- item during a rebalance. Ungated items always pass.
function M.shop_item_unlocked(id, item)
  if item.requires_rank_all then
    for _, tid in ipairs(track_data.track_order()) do
      if not M.rank_at_least(tid, item.requires_rank_all) then return false end
    end
    return true
  end
  if not item.requires_rank then return true end
  return M.rank_at_least(id, item.requires_rank)
end

-- The next corridor track the player may buy this loop, or nil. It's the first
-- unowned track, but only while that track is within the loop's purchase ceiling
-- (top_track_index) - past the ceiling there's nothing to buy until a Rebirth
-- raises it. Owned tracks are a contiguous prefix, so the first unowned track is
-- always the one directly above the top owned track.
function M.next_locked_track()
  for _, tid in ipairs(track_data.track_order()) do
    if not State.unlocked[tid] then
      if track_data.get_track_index(tid) > track_data.top_track_index(State.loop) then
        return nil
      end
      return tid
    end
  end
  return nil
end

-- Buys `id` for this loop with cash: the loop's climb, re-paid each Rebirth.
-- Guarded to the current next-buyable track so the loop ceiling can't be skipped.
-- Seeds fresh track state (with the skill tree's floors applied) and its ghost
-- sim. Returns true on success so the caller can navigate onto the new track.
function M.try_unlock_track(id)
  if id ~= M.next_locked_track() then return end
  local cost = track_data.unlock_cost(id)
  if not cost or State.money < cost then return end
  State.money        = State.money - cost
  State.unlocked[id] = true
  if not State.tracks[id] then
    State.tracks[id] = track_data.default_track_state(id, State.coins_unlocked, State.start_coins)
    -- Applies the skill tree's floors (Checkpoint Pass, coin floor) to the
    -- fresh track state.
    persist.rederive_skill_effects()
  end
  ghost.rebuild_sim(id)
  persist.save()
  return true
end

-- Highest-index owned track this loop - the top the player has actually
-- climbed to. Ownership resets to Track 1 each loop and grows by cash purchase,
-- so this tracks progress up the corridor, not the loop ceiling. Drives the
-- buy-next-track row (the next unowned track sits directly above it).
function M.top_owned_track()
  local order = track_data.track_order()
  local top   = order[1]
  for i = 2, #order do
    if State.unlocked[order[i]] then top = order[i] end
  end
  return top
end

-- The track Rebirth and Nirvana fire from: the loop's ceiling track - the top
-- track this loop makes buyable (track_data.top_track), the true top of the
-- climb. This is the loop ceiling, not merely the top the player has bought so
-- far, so the loop-enders stay hidden until the climb has reached the top. It's
-- reachable (navigable, ownable) only once bought all the way up, at which point
-- it equals top_owned_track.
function M.rebirth_track()
  return track_data.top_track(State.loop)
end

-- Cash price of a Rebirth: the authored exit price of the track it fires from,
-- the loop's ceiling track (Track 2 on loop 2, Track 4 at loop 4+). Flat per
-- track, no per-loop escalation - past the last track every loop pays Track 4's
-- cost.
function M.rebirth_cost()
  return track_data.rebirth_cost(M.rebirth_track())
end

-- True once the player can afford to Rebirth. Edge-triggers the "Rebirth
-- available!" announcement (see scenes/race.lua finish_race): the race that
-- earns the fare is the news.
function M.rebirth_affordable()
  return State.money >= M.rebirth_cost()
end

-- Rebirth: stay in Samsara, reset, and climb again stronger. Fires only from
-- the loop's ceiling track (where the row renders) once the fare is earned; the
-- ¥ banked from this loop's race ranks is already in the skill tree, waiting to
-- be spent in the garage the reset drops the player into.
function M.prestige()
  if not M.rebirth_affordable() then return end
  if State.active_track ~= M.rebirth_track() then return end
  sfx.play("loop_complete")
  persist.start_new_loop()
end

-- Nirvana: escape the loop - the eventual win condition. Non-functional for
-- now; the row renders and is affordability-gated (players can't reach the $1M
-- price yet), and clicking is a no-op until the true-end effect (fanfare /
-- credits / win state) is designed.
function M.buy_nirvana()
  -- TBD: true-end.
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
  return tstate.ghosts * (pay / period) * ghost.SPEED_MULT * State.ghost_efficiency
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
-- (ghosts/coins/checkpoints).
function M.shop_item(kind)
  return track_data.upgrade_item(kind)
      or track_data.track_shop_item(State.active_track, kind)
end

function M.upgrade_cost(kind)
  local id = State.active_track
  local u  = M.shop_item(kind)
  if not u then return nil end
  if kind == "coins" then
    local free   = track_data.start_coin_floor(id, State.coins_unlocked, State.start_coins)
    local bought = State.tracks[id].coins - free
    if bought >= track_data.buyable_coins(id, State.coins_unlocked) then return nil end
    return math.floor(u.base_cost * (u.growth ^ bought))
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

-- Ghosts replay the track's recorded lap, so they stay locked behind one
-- completed race on that track (nothing to replay otherwise). It's the only
-- first-race gate: tracks are cash-bought (loop-capped) and Rebirth fires from
-- the top owned track, neither gated on a first race.
function M.needs_first_race(id, kind)
  local tstate = State.tracks[id]
  if not tstate then return true end
  if tstate.ghost_line then return false end
  return kind == "ghosts"
end

-- Banks the ¥ newly earned on `id` this loop: the gap between the track's best
-- rank this loop (its established rank) and the highest tier already paid.
-- Called on race finish, after ghost.promote(). Best-rank-per-track per loop -
-- re-racing at or below the paid tier banks nothing, so there's no farm - and
-- the ¥ lands in the skill tree immediately, to be spent only once the player
-- Rebirths into the garage. Returns the ¥ credited (0 if none).
function M.bank_race_yen(id)
  local tstate = State.tracks[id]
  if not tstate then return 0 end
  local rank = M.track_rank(id)
  local gain = RANK_YEN[rank] - (RANK_YEN[tstate.paid_rank or "D"] or 0)
  if gain <= 0 then return 0 end
  tstate.paid_rank        = rank
  State.skill_tree.points = State.skill_tree.points + gain
  return gain
end

function M.try_buy(kind)
  local id   = State.active_track
  local cost = M.upgrade_cost(kind)
  if cost == nil then return end
  if not M.shop_item_unlocked(id, M.shop_item(kind)) then return end
  if M.needs_first_race(id, kind) then return end
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
  car.apply_upgrades(State.car, State.accel, State.top_speed, State.drift >= 1, State.drift_boost >= 1, State.boost)
  persist.save()
end

function M.bank(event)
  local id     = event.track_id
  local tstate = State.tracks[id]
  local mult   = M.rank_mult(id, tstate.best_rate)
  -- Ghost income only, so the Slipstream skill multiplier applies here but not
  -- to the player's live-race pay (player_pay / pay_for_mult stay unscaled).
  local pay    = M.track_pay(id) * mult * State.ghost_efficiency
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
