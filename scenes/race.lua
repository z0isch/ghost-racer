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

local GHOST_RACE_ALPHA = 0.03

local countdown_time   = 0

local M                = {}

function get_hints()
  local accel_hint = input.mapping_for(input.BTN1) .. " to accelerate\n"
  local right_hint = input.mapping_for(input.RIGHT) .. " to turn clockwise\n"
  local left_hint  = input.mapping_for(input.LEFT) .. " to turn counter clockwise"
  return accel_hint .. right_hint .. left_hint
end

function M.enter()
  State.race = {
    next_checkpoint = 1,
    time            = 0,
    phase           = State.seen_help and "countdown" or "help",
    earned          = 0,
    coins_earned    = 0,
    coins_collected = {},
    first_race      = not State.seen_help,
  }
  ghost.reset_recording()
  car.apply_upgrades(State.accel, State.top_speed)
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
  local race                 = State.race
  local id                   = State.active_track
  local tstate               = State.tracks[id]
  local recording            = ghost.get_recording()
  race.run_time              = race.time

  if not State.coins_collected then
    ghost.promote()
    persist.save()
    SceneGoto("buy")
    return
  end

  race.phase                 = "result"
  local has_baseline         = tstate.ghost_line ~= nil
  race.has_baseline          = has_baseline
  race.run_cash_rate         = economy.lap_cash_rate(recording)
  race.run_coin_rate         = economy.lap_coin_rate(recording)
  race.run_mult              = economy.speed_mult(race.run_time)
  race.ghost_mult            = economy.speed_mult(tstate.best_time)
  race.result_start_time     = usagi.elapsed
  local ghosts               = tstate.ghosts
  race.run_total_rate        = ghosts * race.run_cash_rate * race.run_mult
  race.ghost_total_rate      = economy.track_cash_rate(id)
  race.run_total_coin_rate   = ghosts * race.run_coin_rate * race.run_mult
  race.ghost_total_coin_rate = economy.track_coin_rate(id)
  if has_baseline then
    race.time_delta      = tstate.best_time - race.time
    race.cash_rate_delta = race.run_total_rate - race.ghost_total_rate
    race.coin_rate_delta = race.run_total_coin_rate - race.ghost_total_coin_rate
  end
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
  elseif race.phase == "racing" then
    local id    = State.active_track
    local tdata = track_data.TRACKS[id]

    car.update(dt, tdata.map)
    race.time = race.time + dt
    ghost.record(race.time, car.pose())

    local car_rect = car.rect()

    for ci = 1, road.active_coin_count(State.tracks[id].coins, tdata.coins) do
      local coin = tdata.coins[ci]
      if not race.coins_collected[ci]
          and util.rect_overlap(car_rect, track_data.coin_rect(coin)) then
        race.coins_collected[ci] = true
        State.coins              = State.coins + economy.COIN_PAY
        State.coins_collected    = true
        race.coins_earned        = race.coins_earned + economy.COIN_PAY
        sfx.play("coin")
        popups.spawn({
          amount   = economy.COIN_PAY,
          currency = "coin",
          x        = coin.col * track_data.tile_size + track_data.tile_size / 2,
          y        = coin.row * track_data.tile_size,
        })
      end
    end

    local cp = tdata.checkpoints[race.next_checkpoint]
    if cp and util.rect_overlap(car_rect, track_data.checkpoint_rect(cp)) then
      State.money = State.money + economy.CHECKPOINT_PAY
      race.earned = race.earned + economy.CHECKPOINT_PAY
      popups.spawn({
        amount   = economy.CHECKPOINT_PAY,
        currency = "cash",
        x        = car_rect.x + car.SIZE / 2,
        y        = car_rect.y,
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
  dim.draw(usagi.GAME_W, usagi.GAME_H)

  local title       = "How To Race"
  local title_scale = 3
  local tw          = usagi.measure_text(title) * title_scale
  local ty          = 70


  local body_scale = 2
  local bw         = usagi.measure_text(get_hints()) * body_scale
  local by         = ty + 50

  local btn_w      = 180
  local btn_y      = by + 90

  local panel_pad  = 16
  local panel_w    = math.max(tw, bw, btn_w) + panel_pad * 2
  local panel_x    = math.floor((usagi.GAME_W - panel_w) / 2)
  local panel_y    = ty - panel_pad
  local panel_h    = (btn_y + 32 + panel_pad) - panel_y
  gfx.rect_fill(panel_x, panel_y, panel_w, panel_h, gfx.COLOR_DARK_GRAY)
  gfx.rect(panel_x, panel_y, panel_w, panel_h, gfx.COLOR_WHITE)

  local tx = math.floor((usagi.GAME_W - tw) / 2)
  gfx.text_ex(title, tx, ty, title_scale, 0, gfx.COLOR_WHITE, 1)

  local bx = math.floor((usagi.GAME_W - bw) / 2)
  gfx.text_ex(get_hints(), bx, by, body_scale, 0, gfx.COLOR_LIGHT_GRAY, 1)

  local btn_x = math.floor((usagi.GAME_W - btn_w) / 2)
  if ui.button("GOT IT", btn_x, btn_y, { w = btn_w, scale = 2 }) then
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

local function draw_race_result()
  dim.draw(usagi.GAME_W, usagi.GAME_H)
  local race      = State.race
  local coin_icon = economy.COIN_ICON

  local function centered_text(text, y, scale, color)
    local tw = usagi.measure_text(text) * scale
    local cx = math.floor((usagi.GAME_W - tw) / 2)
    gfx.text_ex(text, cx, y, scale, 0, color or gfx.COLOR_WHITE, 1)
  end

  local function delta_color(v)
    if v > 0 then
      return gfx.COLOR_GREEN
    elseif v < 0 then
      return gfx.COLOR_RED
    else
      return gfx.COLOR_LIGHT_GRAY
    end
  end

  local function centered_rate_delta(value_text, unit_text, value_color, unit_color, y, scale)
    local vw = usagi.measure_text(value_text) * scale
    local uw = usagi.measure_text(unit_text) * scale
    local cx = math.floor((usagi.GAME_W - (vw + uw)) / 2)
    gfx.text_ex(value_text, cx, y, scale, 0, value_color, 1)
    gfx.text_ex(unit_text, cx + vw, y, scale, 0, unit_color, 1)
  end

  local owns_ghost = economy.owns_any_ghost()
  local show_rates = owns_ghost
  local show_coins = State.coins_collected

  local y = 80

  if race.has_baseline then
    local time_col  = delta_color(race.time_delta)
    local time_sign = race.time_delta >= 0 and "-" or "+"
    centered_text(string.format("%s%.2fs", time_sign, math.abs(race.time_delta)), y, 2, time_col)
    y = y + 22

    if show_rates then
      local cash_col  = delta_color(race.cash_rate_delta)
      local cash_sign = race.cash_rate_delta >= 0 and "+" or ""
      centered_rate_delta(string.format("%s%.2f", cash_sign, race.cash_rate_delta),
        " $/sec", cash_col, gfx.COLOR_GREEN, y, 2)
      y = y + 22
    end

    if show_rates and show_coins then
      local coin_col  = delta_color(race.coin_rate_delta)
      local coin_sign = race.coin_rate_delta >= 0 and "+" or ""
      centered_rate_delta(string.format("%s%.2f", coin_sign, race.coin_rate_delta),
        " " .. coin_icon .. "/sec", coin_col, gfx.COLOR_YELLOW, y, 2)
      y = y + 22
    end
    y = y + 12

    if owns_ghost then
      local bw   = 150
      local btnm = 8
      local lx   = math.floor((usagi.GAME_W - bw * 2 - btnm) / 2)
      if ui.button("USE THIS RUN", lx, y, { w = bw, scale = 2 }) then
        ghost.promote()
        persist.save()
        SceneGoto("buy")
      end
      if ui.button("KEEP CURRENT", lx + bw + btnm, y, { w = bw, scale = 2 }) then
        persist.save()
        SceneGoto("buy")
      end
    else
      local bw = 180
      if ui.button("Ok", math.floor((usagi.GAME_W - bw) / 2), y, { w = bw, scale = 2 }) then
        ghost.promote()
        persist.save()
        SceneGoto("buy")
      end
    end
  else
    centered_text(string.format("Time %.2fs", race.run_time), y, 2, gfx.COLOR_WHITE)
    y = y + 22
    if show_rates then
      centered_text(string.format("%.2f/sec", race.run_cash_rate), y, 2, gfx.COLOR_WHITE)
      y = y + 22
    end
    if show_rates and show_coins then
      centered_text(string.format("%.2f/sec", race.run_coin_rate), y, 2, gfx.COLOR_WHITE)
      y = y + 22
    end
    y = y + 12

    local bw = 180
    if ui.button("Ok", math.floor((usagi.GAME_W - bw) / 2), y, { w = bw, scale = 2 }) then
      ghost.promote()
      persist.save()
      SceneGoto("buy")
    end
  end
end

function M.draw()
  local id    = State.active_track
  local tdata = track_data.TRACKS[id]
  road.draw_track(tdata.map)
  local race = State.race
  if race.phase ~= "result" then
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
  car.draw_flames()
  car.draw()
  popups.draw()
  hud.draw()

  if race.phase == "help" then
    draw_help()
  elseif race.phase == "countdown" then
    draw_countdown()
  elseif race.phase == "result" then
    draw_race_result()
  else
    if not race.first_race then
      if ui.button("QUIT", 5, 5, { w = 50 }) then
        persist.save()
        SceneGoto("buy")
      end
    end
    if race.first_race then
      local hw = usagi.measure_text(get_hints())
      local hx = math.floor((usagi.GAME_W - hw) / 2)
      gfx.text_ex(get_hints(), hx, 34, 1, 0, gfx.COLOR_LIGHT_GRAY, 1)
    end
  end
end

return M
