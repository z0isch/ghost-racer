local basic_map = require "tile-map.basic"
local ui = require "ui"
local dim = require "dim"

local game_width = 640
local game_height = 352

local tile_size = basic_map.tilewidth
local map_layer = basic_map.layers[1].data
local map_width = basic_map.width
local map_height = basic_map.height

local tile_colors = {
  [0] = gfx.COLOR_DARK_BLUE,
  [1] = gfx.COLOR_INDIGO,
  [2] = gfx.COLOR_BLACK,
}

local function get_tile(x, y)
  local col = math.floor(x / tile_size)
  local row = math.floor(y / tile_size)
  if col < 0 or col >= map_width or row < 0 or row >= map_height then
    return 0
  end
  return map_layer[row * map_width + col + 1]
end

local CAR_SIZE = 16
local CAR_MARGIN = 3
local SPAWN_TILE = { col = 0, row = 10 }

local function car_on_road(x, y)
  local inner = CAR_SIZE - CAR_MARGIN - 1
  return get_tile(x + CAR_MARGIN, y + CAR_MARGIN) == 1
      and get_tile(x + inner, y + CAR_MARGIN) == 1
      and get_tile(x + CAR_MARGIN, y + inner) == 1
      and get_tile(x + inner, y + inner) == 1
end

-- ---------------------------------------------------------------------------
-- Economy / upgrade tuning
-- ---------------------------------------------------------------------------

local CHECKPOINT_PAY = 25 -- $ credited live as each checkpoint is hit

-- Car stats derive from upgrade levels at race start: base + level * step.
local ACCEL_BASE, ACCEL_STEP = 50, 15
local TOP_VEL_BASE, TOP_VEL_STEP = 200, 30

local PER_GHOST_RATE = 8 -- $/min per ghost at efficiency level 0
local EFF_STEP = 0.5     -- efficiency multiplier = 1 + level * EFF_STEP

-- A faster best lap makes ghosts complete the loop quicker, scaling passive
-- income by RATE_PAR_TIME / best_time.
local RATE_PAR_TIME = 1000

-- Geometric cost curve per upgrade: cost(level) = base_cost * growth^level,
-- capped at `max`. The ghost upgrade overrides level 0 -> 1 to be FREE.
local UPGRADES = {
  ghosts     = { max = 8, base_cost = 75, growth = 1.55 },
  efficiency = { max = 5, base_cost = 120, growth = 1.8 },
  accel      = { max = 5, base_cost = 90, growth = 1.7 },
  top_speed  = { max = 5, base_cost = 90, growth = 1.7 },
}

local CHECKPOINTS = {
  { x = 560, y = 96, w = 80, h = 176 },
  { x = 0,   y = 96, w = 80, h = 176 },
}

local GHOST_ALPHA = 0.4

-- ---------------------------------------------------------------------------
-- Engine entrypoints
-- ---------------------------------------------------------------------------

function _config()
  return {
    name = "Usagi Test",
    game_id = "com.usagi.drift",
    game_width = game_width,
    game_height = game_height,
  }
end

-- Transient (non-persisted) runtime state -----------------------------------

local skid_marks = {}
local skid_prev = nil

local car = {
  x = SPAWN_TILE.col * tile_size,
  y = SPAWN_TILE.row * tile_size,
  vel = 0,
  top_vel = TOP_VEL_BASE,
  facing_angle = 0,
  vel_angle = 0,
  turn_speed = 0.03,
  drift_turn_speed = 0.06,
  drift_slide = math.pi / 8,
  drift_deccel = 180,
  accel = ACCEL_BASE,
  deccel = 150,
  is_drifitng = false,
  turn_speed_factor = 0.0001,
  skid_max_age = 2.5,
  skid_max_count = 200,
  boost_value = 120,
  boost_length = 1.2,
  drift_threshold = .6,
  drift_time = 0,
  boost_ready = false,
  boost_time_remaining = 0,
}

-- Race recording buffer (samples of the current race run).
local run_samples = {}

local countdown_time = 0
local buy_ghost_time = 0 -- shared replay clock for buy-mode ghosts

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

local function default_state()
  return {
    mode = "buy",
    money = 0,
    upgrades = { ghosts = 0, efficiency = 0, accel = 0, top_speed = 0 },
    ghost_line = nil,
    best_time = nil,
    race = { next_checkpoint = 1, time = 0, phase = "countdown", earned = 0 },
  }
end

---Derive the car's runtime stats from the persisted upgrade levels.
local function apply_car_upgrades()
  car.accel = ACCEL_BASE + State.upgrades.accel * ACCEL_STEP
  car.top_vel = TOP_VEL_BASE + State.upgrades.top_speed * TOP_VEL_STEP
end

local function save_game()
  usagi.save({
    money = State.money,
    upgrades = State.upgrades,
    ghost_line = State.ghost_line,
    best_time = State.best_time,
  })
end

function _init()
  local loaded = usagi.load()
  State = default_state()
  if loaded then
    State.money = loaded.money or 0
    if loaded.upgrades then
      State.upgrades.ghosts = loaded.upgrades.ghosts or 0
      State.upgrades.efficiency = loaded.upgrades.efficiency or 0
      State.upgrades.accel = loaded.upgrades.accel or 0
      State.upgrades.top_speed = loaded.upgrades.top_speed or 0
    end
    State.ghost_line = loaded.ghost_line
    State.best_time = loaded.best_time
  end
  -- mode always resets to buy on load; car stats re-derive from upgrades.
  State.mode = "buy"
  apply_car_upgrades()
end

-- ---------------------------------------------------------------------------
-- Economy helpers
-- ---------------------------------------------------------------------------

---Cost to raise `kind` from its current level. 0 = free, nil = at cap.
---@param kind string
---@return number|nil
local function upgrade_cost(kind)
  local u = UPGRADES[kind]
  local lvl = State.upgrades[kind]
  if lvl >= u.max then return nil end
  if kind == "ghosts" and lvl == 0 then return 0 end -- first ghost is free
  return math.floor(u.base_cost * (u.growth ^ lvl))
end

---Speed bonus to passive income from the best lap time (see RATE_PAR_TIME).
local function rate_speed_factor()
  local bt = State.best_time
  if not bt or bt <= 0 then return 1 end
  return RATE_PAR_TIME / bt
end

---Passive income rate in $/min from currently owned ghosts.
local function passive_rate_per_min()
  local eff = 1 + State.upgrades.efficiency * EFF_STEP
  return State.upgrades.ghosts * PER_GHOST_RATE * eff * rate_speed_factor()
end

-- ---------------------------------------------------------------------------
-- Angle / replay math
-- ---------------------------------------------------------------------------

---Normalize an angle to be between 0 and 2 * PI
local function nomalize_angle(angle)
  return angle - 2 * math.pi * math.floor(angle / (2 * math.pi))
end

---Lerp between two angles, taking the shortest arc
local function lerp_angle(a, b, t)
  local diff = b - a
  diff = diff - 2 * math.pi * math.floor((diff + math.pi) / (2 * math.pi))
  return a + diff * math.min(t, 1)
end

---Interpolate a recorded line's transform at a given time into the run.
---@param line table|nil  array of {t,x,y,angle,drift}
---@param time number
---@return table|nil
local function sample_line_at(line, time)
  if not line or #line == 0 then return nil end

  if time <= line[1].t then return line[1] end
  local last = line[#line]
  if time >= last.t then return last end

  for i = 1, #line - 1 do
    local a = line[i]
    local b = line[i + 1]
    if time >= a.t and time <= b.t then
      local span = b.t - a.t
      local t = 0
      if span > 0 then t = (time - a.t) / span end
      return {
        x = util.lerp(a.x, b.x, t),
        y = util.lerp(a.y, b.y, t),
        angle = lerp_angle(a.angle, b.angle, t),
        drift = a.drift,
      }
    end
  end

  return last
end

---Total duration of the stored ghost line (seconds), or 0 if none.
local function ghost_line_duration()
  local line = State.ghost_line
  if not line or #line == 0 then return 0 end
  return line[#line].t
end

-- ---------------------------------------------------------------------------
-- Car physics + recording (shared by race mode)
-- ---------------------------------------------------------------------------

local function reset_car()
  car.x = SPAWN_TILE.col * tile_size
  car.y = SPAWN_TILE.row * tile_size
  car.vel = 0
  car.facing_angle = 0
  car.vel_angle = 0
  car.is_drifitng = false
  car.drift_time = 0
  car.boost_ready = false
  car.boost_time_remaining = 0
  skid_marks = {}
  skid_prev = nil
end

---Advance the player car one frame and append a sample to run_samples.
local function update_car(dt)
  local holding_left = input.held(input.LEFT)
  local holding_right = input.held(input.RIGHT)
  local is_drifitng = false
  if input.held(input.BTN2) then is_drifitng = true end

  local target_vel_angle = car.facing_angle
  if is_drifitng and (holding_left or holding_right) then
    local dir = 1
    if holding_left then dir = -1 end
    target_vel_angle = car.facing_angle + (dir * .005 * car.vel)
  end

  if is_drifitng then
    car.vel_angle = lerp_angle(car.vel_angle, target_vel_angle, car.drift_slide * dt)
  else
    car.vel_angle = car.facing_angle
  end

  local drift_factor = 1
  if is_drifitng then drift_factor = 1.1 end
  local vel_vec = util.vec_from_angle(car.vel_angle, drift_factor * car.vel * dt)
  local new_x = util.clamp(car.x + vel_vec.x, 0, game_width - CAR_SIZE)
  local new_y = util.clamp(car.y + vel_vec.y, 0, game_height - CAR_SIZE)

  if car_on_road(new_x, new_y) then
    car.x = new_x
    car.y = new_y
  elseif car_on_road(new_x, car.y) then
    car.x = new_x
    car.vel = car.vel * 0.5
  elseif car_on_road(car.x, new_y) then
    car.y = new_y
    car.vel = car.vel * 0.5
  else
    car.vel = 0
  end

  local effective_top_vel = car.top_vel

  if input.held(input.BTN1)
  then
    car.vel = util.clamp(car.vel + car.accel * dt, 0, effective_top_vel)
  else
    car.vel = util.clamp(car.vel - car.deccel * dt, 0, effective_top_vel)
  end

  if is_drifitng then
    car.vel = util.clamp(car.vel - car.drift_deccel * dt, 0, effective_top_vel)
  end

  if holding_left or holding_right
  then
    local turn_speed = car.turn_speed
    if is_drifitng then turn_speed = car.drift_turn_speed end

    local dir = 1
    if holding_left then dir = -1 end

    car.facing_angle = nomalize_angle(car.facing_angle + (dir * turn_speed / (1 + car.vel * car.turn_speed_factor)))
  end

  if is_drifitng
  then
    car.is_drifitng = true
    car.drift_time = car.drift_time + dt
    if car.drift_time >= car.drift_threshold and not car.boost_ready then
      car.boost_ready = true
    end
  else
    if car.boost_ready then
      car.boost_time_remaining = car.boost_length
      car.vel = math.min(car.vel + car.boost_value, car.top_vel)
      car.boost_ready = false
    end
    car.is_drifitng = false
    car.drift_time = 0
  end

  if car.boost_time_remaining > 0 then
    car.boost_time_remaining = car.boost_time_remaining - dt
  end

  if is_drifitng then
    local cx = car.x + 8
    local cy = car.y + 8
    local back = util.vec_from_angle(car.facing_angle + math.pi, 5)
    local perp = util.vec_from_angle(car.facing_angle + math.pi / 2, 4)
    local lx = cx + back.x - perp.x
    local ly = cy + back.y - perp.y
    local rx = cx + back.x + perp.x
    local ry = cy + back.y + perp.y
    if skid_prev then
      skid_marks[#skid_marks + 1] = {
        lx1 = skid_prev.lx,
        ly1 = skid_prev.ly,
        lx2 = lx,
        ly2 = ly,
        rx1 = skid_prev.rx,
        ry1 = skid_prev.ry,
        rx2 = rx,
        ry2 = ry,
        age = 0
      }
      if #skid_marks > car.skid_max_count then
        table.remove(skid_marks, 1)
      end
    end
    skid_prev = { lx = lx, ly = ly, rx = rx, ry = ry }
  else
    skid_prev = nil
  end

  local i = 1
  while i <= #skid_marks do
    skid_marks[i].age = skid_marks[i].age + dt
    if skid_marks[i].age > car.skid_max_age then
      table.remove(skid_marks, i)
    else
      i = i + 1
    end
  end

  local race = State.race
  race.time = race.time + dt
  run_samples[#run_samples + 1] = {
    t = race.time,
    x = car.x,
    y = car.y,
    angle = car.facing_angle,
    drift = car.is_drifitng,
  }
end

-- ---------------------------------------------------------------------------
-- Mode transitions
-- ---------------------------------------------------------------------------

local function start_race()
  State.mode = "race"
  State.race = { next_checkpoint = 1, time = 0, phase = "countdown", earned = 0 }
  run_samples = {}
  apply_car_upgrades()
  reset_car()
  countdown_time = 3
  save_game()
end

local function return_to_buy()
  State.mode = "buy"
  save_game()
end

---Finalize a fully completed race: maybe promote its line as the new best.
local function finish_race()
  local race = State.race
  race.phase = "result"

  local prev_best = State.best_time
  local prev_rate = passive_rate_per_min()
  if prev_best == nil or race.time < prev_best then
    State.ghost_line = run_samples
    State.best_time = race.time
    race.improved = true
    -- time_delta only exists when there was a prior best to beat.
    race.time_delta = prev_best and (prev_best - race.time) or nil
    -- rate_delta: how much the faster lap raised passive income.
    race.rate_delta = passive_rate_per_min() - prev_rate
  end

  save_game()
end

-- ---------------------------------------------------------------------------
-- Update
-- ---------------------------------------------------------------------------

---Accrue ghost passive income for this frame. Active in both modes so ghosts
---keep paying out while you race.
local function accrue_passive(dt)
  local rate = passive_rate_per_min()
  if rate > 0 then
    State.money = State.money + rate * dt / 60
  end
end

local function update_buy(dt)
  buy_ghost_time = buy_ghost_time + dt
  accrue_passive(dt)
end

local function update_race(dt)
  local race = State.race

  accrue_passive(dt)

  if race.phase == "countdown" then
    countdown_time = countdown_time - dt
    if countdown_time <= 0 then
      countdown_time = 0
      race.phase = "racing"
    end
    return
  end

  if race.phase ~= "racing" then return end

  update_car(dt)

  -- Live per-checkpoint crediting against the single active checkpoint.
  local cp = CHECKPOINTS[race.next_checkpoint]
  if cp then
    local car_rect = { x = car.x, y = car.y, w = CAR_SIZE, h = CAR_SIZE }
    if util.rect_overlap(car_rect, cp) then
      State.money = State.money + CHECKPOINT_PAY
      race.earned = race.earned + CHECKPOINT_PAY
      race.next_checkpoint = race.next_checkpoint + 1
      if race.next_checkpoint > #CHECKPOINTS then
        finish_race()
      end
    end
  end
end

function _update(dt)
  if State.mode == "race" then
    update_race(dt)
  else
    update_buy(dt)
  end
end

-- ---------------------------------------------------------------------------
-- Draw
-- ---------------------------------------------------------------------------

local function draw_track()
  for row = 0, map_height - 1 do
    for col = 0, map_width - 1 do
      local tile = map_layer[row * map_width + col + 1]
      gfx.rect_fill(col * tile_size, row * tile_size, tile_size, tile_size, tile_colors[tile] or gfx.COLOR_INDIGO)
    end
  end
end

local function draw_skid_marks()
  for _, mark in ipairs(skid_marks) do
    gfx.line(mark.lx1, mark.ly1, mark.lx2, mark.ly2, gfx.COLOR_BLACK)
    gfx.line(mark.rx1, mark.ry1, mark.rx2, mark.ry2, gfx.COLOR_BLACK)
  end
end

local function draw_car()
  local car_tint = gfx.COLOR_WHITE
  if car.boost_ready then
    car_tint = util.flash(usagi.elapsed, 8) and gfx.COLOR_WHITE or gfx.COLOR_GREEN
  end
  gfx.spr_ex(2, car.x, car.y, false, false, car.facing_angle - math.pi / 2, car_tint, 1)
end

---Draw the money readout centered along the top, visible in both modes.
local function draw_money()
  local text = "$" .. math.floor(State.money)
  local scale = 3
  local tw = usagi.measure_text(text) * scale
  local x = math.floor((game_width - tw) / 2)
  gfx.text_ex(text, x + 2, 6 + 2, scale, 0, gfx.COLOR_BLACK, 0.8)
  gfx.text_ex(text, x, 6, scale, 0, gfx.COLOR_WHITE, 1)
end

---Draw the ghost passive rate centered under the money readout, in both modes.
local function draw_rate()
  local text = string.format("%.2f $/sec", passive_rate_per_min() / 60)
  local scale = 2
  local tw = usagi.measure_text(text) * scale
  local x = math.floor((game_width - tw) / 2)
  gfx.text_ex(text, x, 34, scale, 0, gfx.COLOR_WHITE, 1)
end

local function draw_countdown()
  dim.draw(game_width, game_height)
  local text = tostring(math.ceil(countdown_time))
  local scale = 12
  local tw, th = usagi.measure_text(text)
  local x = math.floor((game_width - tw * scale) / 2)
  local y = math.floor((game_height - th * scale) / 2)
  gfx.text_ex(text, x + 2, y + 2, scale, 0, gfx.COLOR_BLACK, 0.8)
  gfx.text_ex(text, x, y, scale, 0, gfx.COLOR_WHITE, 1)
end

-- Buy mode ------------------------------------------------------------------

local function draw_buy_ghosts()
  local count = State.upgrades.ghosts
  local line = State.ghost_line
  if count <= 0 or not line then return end
  local duration = ghost_line_duration()
  if duration <= 0 then return end

  for i = 1, count do
    local offset = (i - 1) / count * duration
    local t = (buy_ghost_time + offset) % duration
    local g = sample_line_at(line, t)
    if g then
      gfx.spr_ex(2, g.x, g.y, false, false, g.angle - math.pi / 2, gfx.COLOR_WHITE, GHOST_ALPHA)
    end
  end
end

local SHOP_COST_W = 90 -- width of the cost button on the right of each row

---Draw one shop row: a "Name (lvl/max)" label on the left and a cost button on
---the right. Returns true when the cost button is clicked (handled by caller).
---@param kind string
---@param label string
---@param x number
---@param y number
---@param w number
---@return boolean clicked, number height
local function shop_button(kind, label, x, y, w)
  local lvl = State.upgrades[kind]
  local max = UPGRADES[kind].max
  local cost = upgrade_cost(kind)

  local cost_text
  if cost == nil then
    cost_text = "MAX"
  elseif cost == 0 then
    cost_text = "FREE"
  else
    cost_text = "$" .. cost
  end

  -- Ghosts also gated on having a recorded line to drive.
  local affordable = cost ~= nil and (cost == 0 or State.money >= cost)
  if kind == "ghosts" and not State.ghost_line then affordable = false end

  local _, th = usagi.measure_text(label)
  local bh = th * 2 + 4

  -- Label sits vertically centered against the button height.
  local label_text = string.format("%s (%d/%d)", label, lvl, max)
  ui.label(label_text, x, y + math.floor((bh - th * 2) / 2))

  local bx = x + w - SHOP_COST_W
  local clicked = ui.button(cost_text, bx, y, { w = SHOP_COST_W, disabled = not affordable })
  return clicked, bh
end

local function try_buy(kind)
  local cost = upgrade_cost(kind)
  if cost == nil then return end
  if kind == "ghosts" and not State.ghost_line then return end
  if cost > 0 and State.money < cost then return end
  State.money = State.money - cost
  State.upgrades[kind] = State.upgrades[kind] + 1
  apply_car_upgrades()
  save_game()
end

local function draw_buy_shop()
  local x, y = 8, 80
  local w = 290
  local gap = 6

  local items = {
    { kind = "ghosts",     label = "Ghost" },
    { kind = "efficiency", label = "Ghost Efficiency" },
    { kind = "accel",      label = "Accel" },
    { kind = "top_speed",  label = "Top Speed" },
  }
  for _, item in ipairs(items) do
    local clicked, bh = shop_button(item.kind, item.label, x, y, w)
    if clicked then try_buy(item.kind) end
    y = y + bh + gap
  end

  -- Prominent RACE button centered along the bottom.
  local race_x = math.floor((game_width - w) / 2)
  if ui.button("RACE", race_x, game_height - 60, { w = w, scale = 3 }) then
    start_race()
  end
end

local function draw_buy()
  draw_track()
  dim.draw(game_width, game_height)
  draw_buy_ghosts()
  draw_money()
  draw_rate()
  draw_buy_shop()
end

-- Race mode -----------------------------------------------------------------

---Replay the best-run ghost during the race, synced to the player's start.
---race.time is 0 the instant the countdown ends and the player can move, so
---sampling the line at race.time keeps the ghost in step with the player.
local function draw_race_ghost()
  if State.upgrades.ghosts <= 0 then return end
  local g = sample_line_at(State.ghost_line, State.race.time)
  if g then
    gfx.spr_ex(2, g.x, g.y, false, false, g.angle - math.pi / 2, gfx.COLOR_WHITE, GHOST_ALPHA)
  end
end

local function draw_active_checkpoint()
  local race = State.race
  local cp = CHECKPOINTS[race.next_checkpoint]
  gfx.rect_fill(cp.x, cp.y, cp.w, cp.h, gfx.COLOR_DARK_GREEN)
  gfx.rect(cp.x, cp.y, cp.w, cp.h, gfx.COLOR_WHITE)
end

local function draw_race_result()
  dim.draw(game_width, game_height)
  local race = State.race

  local function centered(text, y, scale, color)
    local tw = usagi.measure_text(text) * scale
    local x = math.floor((game_width - tw) / 2)
    gfx.text_ex(text, x, y, scale, 0, color or gfx.COLOR_WHITE, 1)
  end

  centered("FINISH", 60, 6)

  local y = 140
  centered(string.format("Time: %.2fs", race.time), y, 3); y = y + 30
  if race.improved and race.time_delta then
    centered(string.format("-%.2fs faster!", race.time_delta), y, 3, gfx.COLOR_GREEN)
    y = y + 30
  end
  centered("Earned: $" .. race.earned, y, 3); y = y + 30
  centered(string.format("Best: %.2fs", State.best_time or race.time), y, 3); y = y + 30
  if race.improved and race.rate_delta and race.rate_delta / 60 >= 0.01 then
    centered(string.format("+%.2f $/sec", race.rate_delta / 60), y, 3, gfx.COLOR_GREEN)
    y = y + 30
  end

  local bw = 200
  if ui.button("CONTINUE", math.floor((game_width - bw) / 2), y + 10, { w = bw, scale = 3 }) then
    return_to_buy()
  end
end

local function draw_race()
  draw_track()

  local race = State.race
  if race.phase ~= "result" then
    draw_active_checkpoint()
  end

  draw_skid_marks()
  draw_race_ghost()
  draw_car()
  draw_money()

  -- Show the live ghost passive rate, since ghosts keep paying mid-race.
  if race.phase ~= "result" then
    draw_rate()
  end

  if race.phase == "countdown" then
    draw_countdown()
  elseif race.phase == "result" then
    draw_race_result()
  else
    -- Active racing: allow quitting early (banked checkpoints are kept).
    if ui.button("QUIT", 8, 40, { w = 120 }) then
      return_to_buy()
    end
  end
end

function _draw(dt)
  if State.mode == "race" then
    draw_race()
  else
    draw_buy()
  end
end
