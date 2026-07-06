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

local countdown_time   = 0

local M                = {}

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
  car.apply_upgrades(State.accel, State.top_speed, State.drift >= 1, State.drift_boost >= 1, State.boost)
  car.reset(track_data.TRACKS[State.active_track].spawn)
  popups.clear()
  countdown_time = 3
  persist.save()
end

function M.exit()
end

local function dismiss_help()
  State.seen_help  = true
  State.race.phase = "countdown"
  countdown_time   = 3
  persist.save()
end

local function finish_race()
  local race      = State.race
  local id        = State.active_track
  local tstate    = State.tracks[id]

  race.run_rate   = race.time > 0 and (race.raw_earned / race.time) or 0
  race.phase      = "finished"
  race.beat_left  = FINISH_BEAT_SECS

  local first_lap = tstate.ghost_line == nil
  local prev_rank = economy.track_rank(id)
  local locked_id = economy.next_locked_track()
  local was_ready = locked_id ~= nil and economy.track_unlock_ready(locked_id)
  ghost.promote()
  local new_rank = economy.track_rank(id)

  if first_lap or new_rank ~= prev_rank then
    local show_unlock = locked_id ~= nil and not was_ready
        and economy.track_unlock_ready(locked_id)
    State.race_modal = {
      track_id    = id,
      rank        = new_rank,
      -- nil on the first lap: the modal then shows the explainer body
      -- instead of rate deltas.
      prev_rank   = not first_lap and prev_rank or nil,
      show_unlock = show_unlock,
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
    countdown_time = countdown_time - (dt * 2)
    if countdown_time <= 0 then
      countdown_time = 0
      race.phase = "racing"
    end
  elseif race.phase == "finished" then
    race.beat_left = race.beat_left - dt
    if race.beat_left <= 0 then
      SceneGoto("buy")
    end
  elseif race.phase == "racing" then
    local id    = State.active_track
    local tdata = track_data.TRACKS[id]

    car.update(dt, tdata.map)
    race.time = race.time + dt
    ghost.record(race.time, car.pose())

    local car_rect = car.rect()
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

local function draw_countdown()
  dim.draw(usagi.GAME_W, usagi.GAME_H)
  local text   = tostring(math.ceil(countdown_time))
  local scale  = 12
  local tw, th = usagi.measure_text(text)
  local x      = math.floor((usagi.GAME_W - tw * scale) / 2)
  local y      = math.floor((usagi.GAME_H - th * scale) / 2)
  gfx.text_ex(text, x, y, scale, 0, gfx.COLOR_WHITE, 1)
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
  car.draw_skid_marks()
  ghost.draw_sim(GHOST_RACE_ALPHA)
  ghost.draw_race_ghost()
  car.draw_boosts()
  car.draw_flames()
  local magnet_r = track_data.magnet_radius(State.magnet)
  if magnet_r then
    local car_rect = car.rect()
    gfx.circ_fill(car_rect.x + car.SIZE / 2, car_rect.y + car.SIZE / 2, magnet_r, gfx.COLOR_BLACK, 0.1)
  end
  car.draw()
  popups.draw()
  hud.draw()

  if race.phase == "help" then
    draw_help()
  elseif race.phase == "countdown" then
    draw_countdown()
  elseif race.phase == "racing" then
    if not race.first_race then
      if ui.button("QUIT", 5, 5, { w = 50 }) then
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
