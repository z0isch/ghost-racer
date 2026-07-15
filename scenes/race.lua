local ui               = require "ui"
local dim              = require "dim"
local hud              = require "hud"
local car              = require "car"
local road             = require "road"
local ghost            = require "ghost"
local economy          = require "economy"
local popups           = require "popups"
local track_data       = require "track_data"
local persist          = require "persist"
local modal            = require "modal"

local GHOST_RACE_ALPHA = 0.05
local FINISH_BEAT_SECS = .2

-- $/sec is compared at cent precision so the modal only fires when the
-- displayed "$%.2f -> $%.2f" values actually differ.
local function cents(v)
  return math.floor(v * 100 + 0.5)
end

local countdown_time  = 0
local countdown_shown = 0

local M               = {}

local function get_hints()
  local accel_hint = input.mapping_for(input.BTN1) .. " to accelerate\n"
  local right_hint = input.mapping_for(input.RIGHT) .. " to turn clockwise\n"
  local left_hint  = input.mapping_for(input.LEFT) .. " to turn counter clockwise"
  local hints      = accel_hint .. right_hint .. left_hint
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
    next_checkpoint = 1,
    time            = 0,
    phase           = State.seen_help and "countdown" or "help",
    raw_earned      = 0,
    coins_collected = {},
    first_race      = not State.seen_help,
  }
  ghost.reset_recording()
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
  local race     = State.race
  local id       = State.active_track
  local tstate   = State.tracks[id]
  local tdata    = track_data.TRACKS[id]

  race.run_rate  = race.time > 0 and (race.raw_earned / race.time) or 0
  race.phase     = "finished"
  race.beat_left = FINISH_BEAT_SECS
  car.stop_engine(State.car)
  sfx.play("applause")

  local first_lap   = tstate.ghost_line == nil
  local had_ghost   = tstate.ghosts > 0
  local prev_rank   = economy.track_rank(id)
  local cash_before = economy.track_cash_rate(id)
  local locked_id   = economy.next_locked_track()
  local was_ready   = locked_id ~= nil and economy.track_unlock_ready(locked_id)
  local nirvana_was = economy.nirvana_ready()
  ghost.promote()
  local new_rank     = economy.track_rank(id)
  local cash_after   = economy.track_cash_rate(id)

  local rank_changed = not first_lap and new_rank ~= prev_rank
  local cash_up      = had_ghost and cents(cash_after) > cents(cash_before)

  if first_lap or rank_changed or cash_up then
    local show_unlock  = locked_id ~= nil and not was_ready
        and economy.track_unlock_ready(locked_id)
    local show_nirvana = not nirvana_was and economy.nirvana_ready()
    local coins_total  = road.active_coin_count(tstate.coins, tdata.coins)
    local coins_got    = 0
    for _ in pairs(race.coins_collected) do coins_got = coins_got + 1 end
    State.race_modal = {
      track_id     = id,
      rank         = new_rank,
      first_lap    = first_lap,
      time         = race.time,
      -- Collected/total coin counts, nil unless the track has coins on it,
      -- so the modal skips the coin stat entirely on coinless tracks.
      coins_got    = coins_total > 0 and coins_got or nil,
      coins_total  = coins_total > 0 and coins_total or nil,
      -- nil unless the rank actually changed: title/body only show the
      -- rank-delta block then.
      prev_rank    = rank_changed and prev_rank or nil,
      -- Ids of the track that just became purchasable / the track selling
      -- Nirvana, nil unless this lap flipped the gate. Ids rather than
      -- booleans so the modal can name the shop to visit.
      show_unlock  = show_unlock and locked_id or nil,
      show_nirvana = show_nirvana and economy.nirvana_track() or nil,
      -- nil unless the track's ghost $/sec went up (requires an owned
      -- ghost). Merged into this same modal rather than a second popup.
      cash_before  = cash_up and cash_before or nil,
      cash_after   = cash_up and cash_after or nil,
    }
  end

  persist.save()
end

function M.update(dt)
  local race = State.race
  ghost.update(dt)
  for _, ev in ipairs(ghost.collect_crossings()) do
    economy.bank(ev)
  end

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

    car.update(State.car, dt, tdata.map)
    race.time = race.time + dt
    ghost.record(race.time, car.pose(State.car))

    local car_rect = car.rect(State.car)
    local magnet_r = track_data.magnet_radius(State.magnet)

    local pay = economy.player_pay(id)
    for ci = 1, road.active_coin_count(State.tracks[id].coins, tdata.coins) do
      local coin = tdata.coins[ci]
      local overlap
      if magnet_r then
        local cx = car_rect.x + car.SIZE / 2
        local cy = car_rect.y + car.SIZE / 2
        overlap  = util.circ_rect_overlap({ x = cx, y = cy, r = magnet_r }, track_data.coin_rect(coin))
      else
        overlap = util.rect_overlap(car_rect, track_data.coin_rect(coin))
      end
      if not race.coins_collected[ci] and overlap then
        race.coins_collected[ci] = true
        State.money              = State.money + pay
        race.raw_earned          = race.raw_earned + tdata.pay
        sfx.play("coin")
        popups.spawn({
          amount = pay,
          x      = coin.col * track_data.tile_size + track_data.tile_size / 2,
          y      = coin.row * track_data.tile_size,
        })
      end
    end

    local cp = tdata.checkpoints[race.next_checkpoint]
    if cp and util.rect_overlap(car_rect, track_data.checkpoint_rect(cp)) then
      State.money     = State.money + pay
      race.raw_earned = race.raw_earned + tdata.pay
      popups.spawn({
        amount = pay,
        x      = car_rect.x + car.SIZE / 2,
        y      = car_rect.y,
      })
      race.next_checkpoint = race.next_checkpoint + 1
      if race.next_checkpoint > #tdata.checkpoints then
        finish_race()
      end
    end
  end

  popups.update(dt)
end

local function draw_help()
  if modal.draw({ title = "How To Race", body = "Hit checkpoints to make $$$!\n\n" .. get_hints() .. "\n" }) then
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

local GO_FLASH_SECS = 0.6

local function draw_go_flash()
  local text   = "GO!"
  local scale  = 10
  local tw, th = usagi.measure_text(text)
  local x      = math.floor((usagi.GAME_W - tw * scale) / 2)
  local y      = math.floor((usagi.GAME_H - th * scale) / 2)
  local alpha  = 1 - (State.race.time / GO_FLASH_SECS) ^ 2
  ui.neon_text(text, x, y, scale, {
    shadow = gfx.COLOR_DARK_PURPLE,
    wobble = 0.12,
    alpha  = alpha,
  })
end

function M.draw()
  local id    = State.active_track
  local tdata = track_data.TRACKS[id]
  road.draw_track(tdata.map)
  local race = State.race
  if race.phase ~= "finished" then
    local checkpoints = tdata.checkpoints
    local active      = race.next_checkpoint
    for i = active, #checkpoints do
      road.draw_checkpoint(checkpoints[i], i, i ~= active, #checkpoints)
    end
  end
  road.draw_coins(tdata.coins, State.tracks[id].coins, race.coins_collected)
  car.draw_skid_marks(State.car)
  ghost.draw_sim(GHOST_RACE_ALPHA)
  ghost.draw_race_ghost()
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
