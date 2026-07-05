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

local GHOST_RACE_ALPHA = 0.1

local countdown_time   = 0

local function round2(n) return math.floor(n * 100 + 0.5) / 100 end

local M = {}

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
    earned          = 0,
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
  local race             = State.race
  local id               = State.active_track
  local tstate           = State.tracks[id]
  local recording        = ghost.get_recording()
  race.run_time          = race.time

  race.phase             = "result"
  local has_baseline     = tstate.ghost_line ~= nil
  race.has_baseline      = has_baseline
  race.run_cash_rate     = economy.lap_cash_rate(recording)
  race.run_rate          = race.run_time > 0 and (race.raw_earned / race.run_time) or 0
  race.run_rank          = economy.rank_for_rate(id, race.run_rate)
  race.result_start_time = usagi.elapsed

  -- The established rank never drops, so the rank that will actually govern
  -- pay once this lap is promoted is the higher of the previous established
  -- rank and this run's rank.
  local prev_rank        = economy.track_rank(id)
  local new_rank         = economy.rank_for_rate(id, math.max(tstate.best_rate or 0, race.run_rate))
  race.prev_rank         = prev_rank
  race.new_rank          = new_rank
  race.rank_up           = has_baseline and new_rank ~= prev_rank

  local new_mult         = economy.RANK_MULTS[new_rank]
  race.ghost_total_rate  = economy.track_cash_rate(id)
  race.run_total_rate    = tstate.ghosts * race.run_cash_rate * new_mult

  local was_a_or_s       = prev_rank == "A" or prev_rank == "S"
  local is_a_or_s        = new_rank == "A" or new_rank == "S"
  if is_a_or_s and not was_a_or_s then
    local idx                  = track_data.get_track_index(id)
    local next_id              = track_data.TRACK_ORDER[idx + 1]
    race.show_track_unlock_msg = next_id ~= nil and not State.unlocked[next_id]
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

    local pay = economy.player_pay(id)
    for ci = 1, road.active_coin_count(State.tracks[id].coins, tdata.coins) do
      local coin = tdata.coins[ci]
      if not race.coins_collected[ci]
          and util.rect_overlap(car_rect, track_data.coin_rect(coin)) then
        race.coins_collected[ci] = true
        State.money              = State.money + pay
        race.earned              = race.earned + pay
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
      race.earned     = race.earned + pay
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

-- Draws the total-rate line, comparing established rate (before this lap is
-- promoted) to the projected rate after promotion. Both sides use the same
-- (sticky) rank multiplier when there's no rank-up, so the delta reflects
-- only the change in ghost-line quality, never a rank swing.
local function draw_total_rate_line(y, scale)
  local race = State.race
  if round2(race.run_total_rate) == round2(race.ghost_total_rate) then
    local text = string.format("$%.2f/sec", race.run_total_rate)
    local sx   = math.floor((usagi.GAME_W - usagi.measure_text(text) * scale) / 2)
    ui.coin_text(text, sx, y, scale, gfx.COLOR_LIGHT_GRAY)
  else
    local went_up = race.run_total_rate > race.ghost_total_rate
    local prefix  = string.format("$%.2f/sec -> ", race.ghost_total_rate)
    local new_val = string.format("$%.2f/sec", race.run_total_rate)
    local total   = usagi.measure_text(prefix .. new_val) * scale
    local sx      = math.floor((usagi.GAME_W - total) / 2)
    gfx.text_ex(prefix, sx, y, scale, 0, gfx.COLOR_WHITE, 1)
    sx = sx + usagi.measure_text(prefix) * scale
    gfx.text_ex(new_val, sx, y, scale, 0, went_up and gfx.COLOR_GREEN or gfx.COLOR_RED, 1)
  end
end

local function draw_race_result()
  dim.draw(usagi.GAME_W, usagi.GAME_H)
  local race      = State.race
  local has_ghost = State.tracks[State.active_track].ghosts > 0

  local function centered_text(text, y, scale, color)
    local tw = usagi.measure_text(text) * scale
    local cx = math.floor((usagi.GAME_W - tw) / 2)
    gfx.text_ex(text, cx, y, scale, 0, color or gfx.COLOR_WHITE, 1)
  end

  local y          = 80
  local rank_scale = 4
  local scale      = 2

  if not race.has_baseline then
    -- First-ever run on this track: just show what rank it earned.
    local run_text = race.run_rank
    local rx       = math.floor((usagi.GAME_W - usagi.measure_text(run_text) * rank_scale) / 2)
    ui.rank_text(run_text, run_text, rx, y, rank_scale)
    y              = y + 44

    local mult     = economy.RANK_MULTS[run_text]
    local your_pay = economy.pay_for_mult(State.active_track, mult)
    local text     = string.format("Your Rate: $%d", your_pay)
    local sx       = math.floor((usagi.GAME_W - usagi.measure_text(text) * scale) / 2)
    ui.coin_text(text, sx, y, scale, gfx.COLOR_WHITE)
    y = y + 30

    if has_ghost then
      local track_text = string.format("Track Rate: $%.2f/sec", race.run_total_rate)
      local tsx        = math.floor((usagi.GAME_W - usagi.measure_text(track_text) * scale) / 2)
      ui.coin_text(track_text, tsx, y, scale, gfx.COLOR_LIGHT_GRAY)
      y = y + 30
    end
  elseif race.rank_up then
    -- Ranked up: celebrate with the arrow and both pay-rate increases.
    local arrow = " -> "
    local total = (usagi.measure_text(race.prev_rank) + usagi.measure_text(arrow)
      + usagi.measure_text(race.new_rank)) * rank_scale
    local rx    = math.floor((usagi.GAME_W - total) / 2)
    rx          = rx + ui.rank_text(race.prev_rank, race.prev_rank, rx, y, rank_scale)
    gfx.text_ex(arrow, rx, y, rank_scale, 0, gfx.COLOR_WHITE, 1)
    rx = rx + usagi.measure_text(arrow) * rank_scale
    ui.rank_text(race.new_rank, race.new_rank, rx, y, rank_scale)
    y                   = y + 44

    local prev_mult     = economy.RANK_MULTS[race.prev_rank]
    local new_mult      = economy.RANK_MULTS[race.new_rank]
    local your_prev_pay = economy.pay_for_mult(State.active_track, prev_mult)
    local your_pay      = economy.pay_for_mult(State.active_track, new_mult)
    local prefix        = string.format("Your Rate up $%d -> ", your_prev_pay)
    local new_pay       = string.format("$%d", your_pay)
    local ptotal        = usagi.measure_text(prefix .. new_pay) * scale
    local sx            = math.floor((usagi.GAME_W - ptotal) / 2)
    gfx.text_ex(prefix, sx, y, scale, 0, gfx.COLOR_WHITE, 1)
    sx = sx + usagi.measure_text(prefix) * scale
    gfx.text_ex(new_pay, sx, y, scale, 0, gfx.COLOR_GREEN, 1)
    y = y + 30

    if has_ghost then
      local prev_pay = economy.track_pay(State.active_track) * prev_mult
      local run_pay  = economy.track_pay(State.active_track) * new_mult
      local gprefix  = string.format("Ghost Rate up $%d -> ", prev_pay)
      local gnew_pay = string.format("$%d", run_pay)
      local gtotal   = usagi.measure_text(gprefix .. gnew_pay) * scale
      local gsx      = math.floor((usagi.GAME_W - gtotal) / 2)
      gfx.text_ex(gprefix, gsx, y, scale, 0, gfx.COLOR_WHITE, 1)
      gsx = gsx + usagi.measure_text(gprefix) * scale
      gfx.text_ex(gnew_pay, gsx, y, scale, 0, gfx.COLOR_GREEN, 1)
      y = y + 30

      draw_total_rate_line(y, scale)
      y = y + 30
    end
  elseif has_ghost then
    -- Ordinary run: rank is safe, only the total rate can move.
    draw_total_rate_line(y, scale)
    y = y + 30
  end

  if race.show_track_unlock_msg then
    centered_text("New track available in the shop!", y, 2, gfx.COLOR_GREEN)
    y = y + 30
  end

  y = y + 15
  local bw = 180
  if ui.button("Ok", math.floor((usagi.GAME_W - bw) / 2), y, { w = bw, scale = 2 }) then
    ghost.promote()
    persist.save()
    SceneGoto("buy")
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
  car.draw_boosts()
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
    local hw = usagi.measure_text(get_hints())
    local hx = usagi.GAME_W - hw
    gfx.text_ex(get_hints(), hx, 0, 1, 0, gfx.COLOR_LIGHT_GRAY, 1)
  end
end

return M
