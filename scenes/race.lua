local ui               = require "ui"
local dim              = require "dim"
local hud              = require "hud"
local car              = require "car"
local road             = require "road"
local ghost            = require "ghost"
local gates            = require "gates"
local economy          = require "economy"
local popups           = require "popups"
local track_data       = require "track_data"
local persist          = require "persist"
local modal            = require "modal"
local reference        = require "reference"

local GHOST_RACE_ALPHA = 0
-- Held on the finished phase before cutting to the buy scene. The rank meter's
-- needle teleports straight to the earned rank on finish (hud.lua), so this is
-- purely a beat to let the player read that final landing spot.
local FINISH_BEAT_SECS = .5
-- Neon headline flashes: GO! at the start, LAP n at each lap rollover. Same
-- decay so the lap flash reads as the same kind of event as the start.
local GO_FLASH_SECS    = 0.6
local LAP_FLASH_SECS   = 0.6

local countdown_time   = 0
local countdown_shown  = 0

local M                = {}

local function get_hints()
  local hints = input.mapping_for(input.BTN1) .. " to brake\n"
  -- Only worth naming once the car can actually flip: with no reverse the
  -- throttle is the whole story and there's no gear to talk about.
  if State.car.reverse_enabled then
    hints = hints .. "\ndouble tap " .. input.mapping_for(input.BTN1) .. " to flip into reverse"
  end
  if State.drift >= 1 then
    hints = hints .. "\n" .. input.mapping_for(input.BTN2) .. " to drift while turning"
  end
  if State.boost >= 1 then
    hints = hints .. "\n" .. input.mapping_for(input.BTN3) .. " to boost"
  end
  return hints
end

function M.enter()
  State.race = {
    -- Runs 1..laps*cp_count; the course index is this wrapped (see update).
    next_checkpoint = 1,
    lap             = 1,
    time            = 0,
    phase           = State.seen_help and "countdown" or "help",
    raw_earned      = 0,
    -- One collected-set per coin list: [1] the lap-1 (gold) coins, [2] the
    -- lap-2 (magenta) ones. Two sets rather than one, because the lists are
    -- parallel and share indices.
    coins_collected = { {}, {} },
    first_race      = not State.seen_help,
  }
  ghost.reset_recording()
  reference.begin(State.active_track)
  car.apply_upgrades(State.car, State.accel, State.top_speed, State.drift >= 1, State.drift_boost >= 1, State.boost)
  car.reset(State.car, track_data.TRACKS[State.active_track].spawn)
  popups.clear()
  countdown_time = 3
  countdown_shown = 0
  persist.save()
end

function M.exit()
end

local function dismiss_help()
  State.seen_help  = true
  State.race.phase = "countdown"
  countdown_time   = 3
  countdown_shown  = 0
  persist.save()
end

local function finish_race()
  local race    = State.race
  local id      = State.active_track
  local tstate  = State.tracks[id]
  local tdata   = track_data.TRACKS[id]

  race.run_rate = race.time > 0 and race.raw_earned / race.time or 0
  race.phase    = "finished"

  -- Dev builds keep the fastest full-course lap per track as the reference
  -- line for the rank meter's arc-length ruler. No-op in release.
  reference.maybe_capture(id, ghost.get_recording(), race.time)
  race.beat_left = FINISH_BEAT_SECS
  car.stop_engine(State.car)
  sfx.play("applause")

  local first_lap = tstate.ghost_line == nil
  local prev_rank = economy.track_rank(id)
  ghost.promote()
  local new_rank     = economy.track_rank(id)
  -- Bank the ¥ this track's best rank is worth this loop (the gap over any
  -- tier already paid). This is the whole climb economy: racing better here
  -- funds a stronger next loop. Skill tree stays unspendable until Rebirth.
  local yen_gained   = economy.bank_race_yen(id)

  local rank_changed = not first_lap and new_rank ~= prev_rank

  if usagi.IS_DEV then
    print(string.format("[race] %s  %.2fs  %d laps  raw %d  run_rate %.2f $/sec  -> %s",
      id, race.time, track_data.effective_laps(id), race.raw_earned, race.run_rate, new_rank))
  end

  if first_lap or rank_changed then
    local coins_total = road.active_coin_count(tstate.coins, tdata.coins)
    if track_data.effective_laps(id) > 1 and tdata.coins2 then
      coins_total = coins_total + road.active_coin_count(tstate.coins2, tdata.coins2)
    end
    local coins_got = 0
    for _, set in ipairs(race.coins_collected) do
      for _ in pairs(set) do coins_got = coins_got + 1 end
    end
    State.race_modal = {
      track_id    = id,
      rank        = new_rank,
      first_lap   = first_lap,
      time        = race.time,
      -- Collected/total coin counts, nil unless the track has coins on it,
      -- so the modal skips the coin stat entirely on coinless tracks.
      coins_got   = coins_total > 0 and coins_got or nil,
      coins_total = coins_total > 0 and coins_total or nil,
      -- nil unless the rank actually changed: title/body only show the
      -- rank-delta block then.
      prev_rank   = rank_changed and prev_rank or nil,
      -- ¥ this race banked toward the climb (nil if none), so the payoff of
      -- racing better is shown where it's earned - not just at Rebirth.
      yen         = yen_gained > 0 and yen_gained or nil,
    }
  end

  persist.save()
end

-- Collect pass over one of a track's coin lists. `mult` is attached to the
-- *list*, not to the lap it's grabbed on: a lap-2 coin always pays double and a
-- lap-1 coin always pays 1x, including when swept up on lap 2. That asymmetry
-- is deliberate - see track_data's LAP_COIN_MULT. It keeps missed lap-1 coins
-- worth doubling back for (they cost only the detour) without making it
-- correct to drive past them on lap 1 on purpose.
local function collect_coins(coins, unlocked, collected, mult, car_rect, magnet_r, pay, raw_pay)
  local race = State.race
  for ci = 1, road.active_coin_count(unlocked, coins) do
    if not collected[ci] then
      local rect = track_data.coin_rect(coins[ci])
      local overlap
      if magnet_r then
        overlap = util.circ_rect_overlap({
          x = car_rect.x + car.SIZE / 2,
          y = car_rect.y + car.SIZE / 2,
          r = magnet_r,
        }, rect)
      else
        overlap = util.rect_overlap(car_rect, rect)
      end
      if overlap then
        collected[ci]   = true
        State.money     = State.money + pay * mult
        race.raw_earned = race.raw_earned + raw_pay * mult
        table.insert(race.events_this_frame, "collect")
        sfx.play("coin")
        popups.spawn({
          amount = pay * mult,
          x      = rect.x + track_data.tile_size / 2,
          y      = rect.y,
        })
      end
    end
  end
end

-- Rolling over into the next lap. On every other race the final checkpoint of a
-- lap *is* the finish line - applause, engine stop, cut to the shop - so a
-- silent rollover reads as the finish failing to fire. The flash and the sfx
-- are what kill that "did it break?" moment; the ruler rewind is what keeps the
-- rank needle honest through the second half.
local function begin_next_lap()
  local race     = State.race
  race.lap       = race.lap + 1
  race.lap_flash = LAP_FLASH_SECS
  reference.next_lap()
  sfx.play("loop_complete")
end

function M.update(dt)
  local race = State.race
  ghost.update(dt)
  for _, ev in ipairs(ghost.collect_crossings()) do
    economy.bank(ev)
  end

  -- Reset every frame regardless of phase, so a collect event from the frame
  -- a race finishes on doesn't linger and keep re-triggering the hud's jump
  -- pop on every subsequent "finished" frame.
  race.events_this_frame = {}

  if race.phase == "help" then
    if input.pressed(input.BTN1) then
      dismiss_help()
    end
  elseif race.phase == "countdown" then
    local shown = math.ceil(countdown_time)
    if shown ~= countdown_shown and shown > 0 then
      countdown_shown = shown
      if shown == 3 then sfx.play("3") end
      if shown == 2 then sfx.play("2") end
      if shown == 1 then sfx.play("1") end
    end
    countdown_time = countdown_time - (dt * 2)
    if countdown_time <= 0 then
      countdown_time = 0
      race.phase = "racing"
      sfx.play("go")
    end
  elseif race.phase == "finished" then
    race.beat_left = race.beat_left - dt
    if race.beat_left <= 0 then
      SceneGoto("buy")
    end
  elseif race.phase == "racing" then
    local id    = State.active_track
    local tdata = track_data.TRACKS[id]

    if not race.first_race and input.key_pressed(input.KEY_Q) then
      car.stop_engine(State.car)
      persist.save()
      SceneGoto("buy")
      return
    end

    local gate_walls
    if tdata.gates and gates.enabled(State.car) then
      gate_walls = gates.apply_walls(tdata.gates, State.car, tdata.map)
    end
    car.update(State.car, dt, tdata.map)
    if gate_walls then
      gates.restore_walls(tdata.map, gate_walls)
    end
    race.time = race.time + dt
    if race.lap_flash then
      race.lap_flash = race.lap_flash - dt
    end
    local pose = car.pose(State.car)
    ghost.record(race.time, pose)
    -- Map the car onto the reference line for the rank meter's projection:
    -- s_live is the car's arc position, t_ref the reference's own time to reach
    -- it. The projection reads t_ref's position, not a time derivative of
    -- s_live, so no smoothing of a per-frame speed is needed here.
    if reference.has() then
      race.s_live, race.t_ref = reference.locate(pose.x, pose.y)
    end

    local car_rect = car.rect(State.car)
    local magnet_r = track_data.magnet_radius(State.magnet)

    local pay = economy.player_pay(id)

    local tstate = State.tracks[id]
    collect_coins(tdata.coins, tstate.coins, race.coins_collected[1], 1,
      car_rect, magnet_r, pay, tdata.pay)
    -- The lap-2 list is inert until lap 2 opens; road.draw_coins freezes their
    -- bob to match, so what's collectable and what looks collectable agree.
    if race.lap > 1 and tdata.coins2 then
      collect_coins(tdata.coins2, tstate.coins2, race.coins_collected[2], track_data.LAP_COIN_MULT,
        car_rect, magnet_r, pay, tdata.pay)
    end

    -- next_checkpoint counts crossings across the whole race, so the course
    -- index wraps: crossing N+1 is checkpoint 1 of lap 2.
    local cp_n = economy.cp_count(id)
    local cp   = tdata.checkpoints[((race.next_checkpoint - 1) % cp_n) + 1]
    if cp and util.rect_overlap(car_rect, track_data.checkpoint_rect(cp)) then
      -- Checkpoints take the multiplier of the lap they're crossed on. Safe to
      -- attach to the lap (unlike coins): they're mandatory and in order, so
      -- there's nothing to sandbag.
      local mult      = track_data.lap_mult(race.lap)
      State.money     = State.money + pay * mult
      race.raw_earned = race.raw_earned + tdata.pay * mult
      -- Every owned checkpoint's pay is already in the projection
      -- (economy.projected_rate counts all upcoming ones at full value, since
      -- crossing them in order is how the race finishes), so crossing one
      -- fires no meter jump -- only coin collects still pop.
      popups.spawn({
        amount = pay * mult,
        x      = car_rect.x + car.SIZE / 2,
        y      = car_rect.y,
      })
      race.next_checkpoint = race.next_checkpoint + 1
      if race.next_checkpoint > economy.race_cp_count(id) then
        finish_race()
      elseif (race.next_checkpoint - 1) % cp_n == 0 then
        begin_next_lap()
      end
    end
  end

  popups.update(dt)
end

local function draw_help()
  if modal.draw({ title = "How To Race", body = "Hit checkpoints to make $$$!\n\nThe car automatically accelerates\n\nUse the left/right arrow keys to turn\n\n" .. get_hints() }) then
    dismiss_help()
  end
end

local COUNTDOWN_COLORS = {
  [3] = gfx.COLOR_PINK,
  [2] = gfx.COLOR_BLUE,
  [1] = gfx.COLOR_YELLOW,
}

local function draw_countdown()
  dim.draw(usagi.GAME_W, usagi.GAME_H)
  local n      = math.ceil(countdown_time)
  local text   = tostring(n)
  local scale  = 12
  local tw, th = usagi.measure_text(text)
  local x      = math.floor((usagi.GAME_W - tw * scale) / 2)
  local y      = math.floor((usagi.GAME_H - th * scale) / 2)
  ui.neon_text(text, x, y, scale, {
    colors = { COUNTDOWN_COLORS[n] or gfx.COLOR_WHITE },
    shadow = gfx.COLOR_DARK_PURPLE,
    wobble = 0.1,
  })
end

-- Centered neon headline, fading out over its own decay curve.
local function draw_flash(text, alpha)
  local scale  = 10
  local tw, th = usagi.measure_text(text)
  local x      = math.floor((usagi.GAME_W - tw * scale) / 2)
  local y      = math.floor((usagi.GAME_H - th * scale) / 2)
  ui.neon_text(text, x, y, scale, {
    shadow = gfx.COLOR_DARK_PURPLE,
    wobble = 0.12,
    alpha  = alpha,
  })
end

local function draw_go_flash()
  draw_flash("GO!", 1 - (State.race.time / GO_FLASH_SECS) ^ 2)
end

-- Same path and decay as GO!, so a lap rollover reads as the same class of
-- event rather than as something going wrong.
local function draw_lap_flash()
  local left = State.race.lap_flash
  draw_flash("LAP " .. State.race.lap, 1 - ((LAP_FLASH_SECS - left) / LAP_FLASH_SECS) ^ 2)
end

function M.draw()
  local id    = State.active_track
  local tdata = track_data.TRACKS[id]
  road.draw_track(tdata.map)
  local race = State.race
  if race.phase ~= "finished" then
    if tdata.gates and gates.enabled(State.car) then
      gates.draw(tdata.gates, State.car)
    end
    -- Only the current lap's remaining checkpoints, numbered 1..N per lap.
    -- next_checkpoint runs 1..laps*N, so this has to wrap regardless: indexing
    -- it raw would run off the end of the list, and labelling straight through
    -- would number track 4's up to 10 - noise, for a label whose whole job is
    -- routing. Wrapping also means lap 2 re-shows the full course.
    local checkpoints = tdata.checkpoints
    local active      = ((race.next_checkpoint - 1) % #checkpoints) + 1
    for i = active, #checkpoints do
      road.draw_checkpoint(checkpoints[i], i, i ~= active, #checkpoints)
    end
  end
  road.draw_coins(id, State.tracks[id].coins, State.tracks[id].coins2, race.coins_collected, race.lap)
  car.draw_skid_marks(State.car)
  ghost.draw_sim(GHOST_RACE_ALPHA)
  ghost.draw_race_ghost()
  car.draw_headlights(State.car)
  car.draw_taillights(State.car)
  car.draw_boosts(State.car)
  car.draw_flames(State.car)
  local magnet_r = track_data.magnet_radius(State.magnet)
  if magnet_r then
    local car_rect = car.rect(State.car)
    gfx.circ_fill(car_rect.x + car.SIZE / 2, car_rect.y + car.SIZE / 2, magnet_r, gfx.COLOR_BLACK, 0.07)
  end
  car.draw(State.car)
  popups.draw()
  hud.draw()

  if race.phase == "help" then
    draw_help()
  elseif race.phase == "countdown" then
    draw_countdown()
  elseif race.phase == "racing" then
    if race.time < GO_FLASH_SECS then
      draw_go_flash()
    end
    if race.lap_flash and race.lap_flash > 0 then
      draw_lap_flash()
    end
    if not race.first_race then
      if ui.button("QUIT", 5, 5, { w = 50 }) then
        car.stop_engine(State.car)
        persist.save()
        SceneGoto("buy")
      end
    end
    local hw = usagi.measure_text(get_hints())
    local hx = usagi.GAME_W - hw
    gfx.text_ex(get_hints(), hx, 0, 1, 0, gfx.COLOR_LIGHT_GRAY, 1)
  end
end

return M
