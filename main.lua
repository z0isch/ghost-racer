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
local SPAWN_TILE = { col = 0, row = 9 }

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

local CHECKPOINT_PAY = 25 -- $ credited live as each checkpoint the player hits

-- $ a single ghost banks each time it crosses a checkpoint. Idle income is
-- emergent: a faster best lap shortens the ghost loop, so checkpoints (and
-- payouts) come around more often. No separate rate formula needed.
local GHOST_CHECKPOINT_PAY = 8

-- Car stats derive from upgrade levels at race start: base + level * step.
local ACCEL_BASE, ACCEL_STEP = 50, 15
local TOP_VEL_BASE, TOP_VEL_STEP = 200, 30

-- Geometric cost curve per upgrade: cost(level) = base_cost * growth^level,
-- capped at `max`. The ghost upgrade overrides level 0 -> 1 to be FREE.
local UPGRADES = {
  ghosts    = { max = 8, base_cost = 75, growth = 1.55 },
  accel     = { max = 5, base_cost = 90, growth = 1.7 },
  top_speed = { max = 5, base_cost = 90, growth = 1.7 },
}

local CHECKPOINTS = {
  { x = 560, y = 96, w = 80, h = 176 },
  { x = 0,   y = 96, w = 80, h = 176 },
}

local GHOST_ALPHA = 0.6
-- Economy ghosts stay on screen during a race but fade way back so they don't
-- fight the player car or the synced rival ghost for attention.
local GHOST_RACE_ALPHA = 0.03

-- Seconds a ghost holds at the end of its recorded lap before looping back to
-- the start -- a small breather so the loop point reads as a lap, not a jump.
local GHOST_LAP_PAUSE = 0.6

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

-- Floating "+$N" popups spawned over the car when a checkpoint is banked.
local cash_pops = {}
local CASH_POP_LIFE = 1.5 -- seconds each popup lives
local CASH_POP_RISE = 50  -- pixels it floats up over its life

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

-- Simulation clock for the idle ghost loop. Advances in buy mode so the
-- staggered ghosts keep looping (and earning) between races.
local sim_time = 0

-- Per-ghost previous loop-phase, for edge-detected checkpoint crossings.
-- Reset on mode switch / ghost purchase / new ghost_line.
local ghost_prev_phase = {}

-- Precomputed checkpoint crossings along ghost_line: one {t, x, y} per
-- checkpoint, the time/position of the lap-completing pass into each zone.
local ghost_cp_crossings = nil

---Scan a recorded line for the time/position of the lap-completing pass into
---each checkpoint zone (rising edge), aligned with CHECKPOINTS. A completed lap
---provably passes through every checkpoint, so each one gets a real crossing.
local function compute_cp_crossings(line)
  if not line or #line == 0 then return nil end
  local crossings = {}
  for ci, cp in ipairs(CHECKPOINTS) do
    -- Seed from the first sample so a car that SPAWNS inside a zone (e.g. the
    -- start/finish checkpoint) doesn't bank a bogus crossing on frame 1 -- only
    -- a genuine re-entry counts, which lands at the end of the lap.
    local inside_prev = util.rect_overlap(
      { x = line[1].x, y = line[1].y, w = CAR_SIZE, h = CAR_SIZE }, cp)
    for _, s in ipairs(line) do
      local inside = util.rect_overlap({ x = s.x, y = s.y, w = CAR_SIZE, h = CAR_SIZE }, cp)
      if inside and not inside_prev then
        crossings[ci] = { t = s.t, x = s.x + CAR_SIZE / 2, y = s.y }
        break
      end
      inside_prev = inside
    end
    -- Fallback (shouldn't trigger for a completed lap): anchor at zone center.
    if not crossings[ci] then
      crossings[ci] = { t = 0, x = cp.x + cp.w / 2, y = cp.y + cp.h / 2 }
    end
  end
  return crossings
end

---Rebuild ghost replay state derived from the current ghost_line.
local function rebuild_ghost_sim()
  ghost_cp_crossings = compute_cp_crossings(State.ghost_line)
  ghost_prev_phase = {}
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

local function default_state()
  return {
    mode = "buy",
    money = 0,
    upgrades = { ghosts = 0, accel = 0, top_speed = 0 },
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
      State.upgrades.accel = loaded.upgrades.accel or 0
      State.upgrades.top_speed = loaded.upgrades.top_speed or 0
    end
    State.ghost_line = loaded.ghost_line
    State.best_time = loaded.best_time
  end
  -- mode always resets to buy on load; car stats re-derive from upgrades.
  State.mode = "buy"
  apply_car_upgrades()
  rebuild_ghost_sim()
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

---Full ghost loop period: the recorded lap plus the end-of-lap pause. While
---phase sits in the trailing pause window, the ghost holds at its finish
---position (sample_line_at clamps to the last recorded sample).
local function ghost_loop_period()
  local duration = ghost_line_duration()
  if duration <= 0 then return 0 end
  return duration + GHOST_LAP_PAUSE
end

---Per-ghost income rate ($/sec) for a recorded lap. Each ghost crosses every
---checkpoint once per loop, so income/loop is fixed; a shorter loop period
---(shorter lap) brings the payouts around more often, raising $/sec.
---@param line table|nil  array of {t,x,y,angle,drift}
---@return number
local function lap_income_rate(line)
  if not line or #line == 0 then return 0 end
  local period = line[#line].t + GHOST_LAP_PAUSE
  if period <= 0 then return 0 end
  return #CHECKPOINTS * GHOST_CHECKPOINT_PAY / period
end

---Total idle $/sec from the ghost economy: per-ghost rate of the stored best
---line scaled by the number of owned ghosts.
local function ghost_income_rate()
  return State.upgrades.ghosts * lap_income_rate(State.ghost_line)
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
  cash_pops = {}
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
  ghost_prev_phase = {}
  save_game()
end

---Finalize a fully completed race: maybe promote its line as the new best.
local function finish_race()
  local race = State.race
  race.phase = "result"

  local prev_best = State.best_time
  local prev_rate = ghost_income_rate()
  if State.ghost_line == nil
      or lap_income_rate(run_samples) > lap_income_rate(State.ghost_line) then
    State.ghost_line = run_samples
    State.best_time = race.time
    race.improved = true
    -- time_delta only exists when there was a prior best to beat.
    race.time_delta = prev_best and (prev_best - race.time) or nil
    -- New best lap -> shorter ghost loop -> ghosts now earn faster.
    rebuild_ghost_sim()
  end

  -- $/sec readout for the result screen, plus the change vs. before the race.
  race.rate = ghost_income_rate()
  race.rate_delta = race.rate - prev_rate

  save_game()
end

-- ---------------------------------------------------------------------------
-- Update
-- ---------------------------------------------------------------------------

---Advance the ghost economy one frame. Every owned ghost loops the recorded
---line and banks GHOST_CHECKPOINT_PAY each time it crosses a checkpoint,
---spawning a dim "+$N" pop at the recorded crossing spot. Runs in both modes so
---idle income never stalls; in race mode the pop fades way back to match the
---faded ghosts.
local function update_ghost_earnings()
  local count = State.upgrades.ghosts
  local line = State.ghost_line
  if count <= 0 or not line then return end
  -- A hot reload re-binds this file-scope local back to nil without re-running
  -- _init, so rebuild the derived crossings from the persisted line on demand.
  if not ghost_cp_crossings then rebuild_ghost_sim() end
  if not ghost_cp_crossings then return end
  local period = ghost_loop_period()
  if period <= 0 then return end

  for i = 1, count do
    local offset = (i - 1) / count * period
    local phase = (sim_time + offset) % period

    local prev = ghost_prev_phase[i]
    if prev then
      for _, c in ipairs(ghost_cp_crossings) do
        local crossed
        if phase >= prev then
          crossed = c.t > prev and c.t <= phase
        else
          -- Looped past the end of the line this frame.
          crossed = c.t > prev or c.t <= phase
        end
        if crossed then
          State.money = State.money + GHOST_CHECKPOINT_PAY
          cash_pops[#cash_pops + 1] = {
            amount = GHOST_CHECKPOINT_PAY,
            x = c.x,
            y = c.y,
            age = 0,
            ghost = true,
            -- Fade race-mode ghost pops to sit alongside the faded ghosts.
            alpha_mul = State.mode == "race" and 0.1 or 1,
          }
        end
      end
    end

    ghost_prev_phase[i] = phase
  end
end

---Age and retire floating cash popups.
local function age_cash_pops(dt)
  local i = 1
  while i <= #cash_pops do
    cash_pops[i].age = cash_pops[i].age + dt
    if cash_pops[i].age > CASH_POP_LIFE then
      table.remove(cash_pops, i)
    else
      i = i + 1
    end
  end
end

local function update_buy(dt)
  sim_time = sim_time + dt
  update_ghost_earnings()
  age_cash_pops(dt)
end

local function update_race(dt)
  local race = State.race

  -- Ghosts keep simulating all through the race -- countdown included -- so
  -- their checkpoint payouts bank just as they do in the buy screen.
  sim_time = sim_time + dt
  update_ghost_earnings()

  if race.phase == "countdown" then
    countdown_time = countdown_time - dt
    if countdown_time <= 0 then
      countdown_time = 0
      race.phase = "racing"
    end
  elseif race.phase == "racing" then
    update_car(dt)

    -- Live per-checkpoint crediting against the single active checkpoint.
    local cp = CHECKPOINTS[race.next_checkpoint]
    if cp then
      local car_rect = { x = car.x, y = car.y, w = CAR_SIZE, h = CAR_SIZE }
      if util.rect_overlap(car_rect, cp) then
        State.money = State.money + CHECKPOINT_PAY
        race.earned = race.earned + CHECKPOINT_PAY
        cash_pops[#cash_pops + 1] = {
          amount = CHECKPOINT_PAY,
          x = car.x + CAR_SIZE / 2,
          y = car.y,
          age = 0,
        }
        race.next_checkpoint = race.next_checkpoint + 1
        if race.next_checkpoint > #CHECKPOINTS then
          finish_race()
        end
      end
    end
  end

  age_cash_pops(dt)
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

---Draw the money readout centered along the top, visible in both modes, with
---the ghost-economy $/sec rate just below it.
local function draw_money()
  local text = string.format("$%.0f", State.money)
  local scale = 3
  local tw, th = usagi.measure_text(text)
  local x = math.floor((game_width - tw * scale) / 2)
  gfx.text_ex(text, x + 2, 6 + 2, scale, 0, gfx.COLOR_BLACK, 0.8)
  gfx.text_ex(text, x, 6, scale, 0, gfx.COLOR_WHITE, 1)

  local rate_text = string.format("$%.2f/sec", ghost_income_rate())
  local rscale = 1
  local rtw = usagi.measure_text(rate_text) * rscale
  local rx = math.floor((game_width - rtw) / 2)
  local ry = 6 + th * scale + 3
  gfx.text_ex(rate_text, rx + 1, ry + 1, rscale, 0, gfx.COLOR_BLACK, 0.8)
  gfx.text_ex(rate_text, rx, ry, rscale, 0, gfx.COLOR_YELLOW, 1)
end

---Draw the floating "+$N" popups rising and fading. Player pops are bold
---(green, scale 2); ghost pops are dim and small so idle income never drowns
---out the player's own checkpoint rewards.
local function draw_cash_pops()
  for _, p in ipairs(cash_pops) do
    local t = p.age / CASH_POP_LIFE
    local scale = p.ghost and 2 or 3
    local alpha = (1 - t) * (p.ghost and 0.6 or 1) * (p.alpha_mul or 1)
    local y = p.y - t * CASH_POP_RISE
    local text = "$" .. p.amount
    local tw = usagi.measure_text(text) * scale
    local x = math.floor(p.x - tw / 2)
    gfx.text_ex(text, x + 1, y + 1, scale, 0, gfx.COLOR_BLACK, 0.8 * alpha)
    gfx.text_ex(text, x, y, scale, 0, gfx.COLOR_GREEN, alpha)
  end
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

---Draw the staggered economy ghosts looping on sim_time. Shared by both modes:
---buy uses GHOST_ALPHA, race passes a fainter alpha so they stay legible behind
---the action.
local function draw_sim_ghosts(alpha)
  local count = State.upgrades.ghosts
  local line = State.ghost_line
  if count <= 0 or not line then return end
  local period = ghost_loop_period()
  if period <= 0 then return end

  for i = 1, count do
    local offset = (i - 1) / count * period
    local t = (sim_time + offset) % period
    local g = sample_line_at(line, t)
    if g then
      gfx.spr_ex(2, g.x, g.y, false, false, g.angle - math.pi / 2, gfx.COLOR_WHITE, alpha)
    end
  end
end

-- Buy mode ------------------------------------------------------------------

local SHOP_COST_W = 50 -- width of the cost button on the right of each row

---Draw one shop row: a "Name (lvl/max)" label on the left and a cost button on
---the right. Returns true when the cost button is clicked (handled by caller).
---@param kind string
---@param label string
---@param x number
---@param y number
---@param w number
---@return boolean clicked, number height
local function shop_button(kind, label, x, y, w)
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

  ui.label(label, x, y + math.floor((bh - th * 2) / 2))

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
  -- Buying a ghost changes N, so the staggered offsets shift: reset phase
  -- tracking to avoid spurious crossings the frame the count changes.
  if kind == "ghosts" then ghost_prev_phase = {} end
  apply_car_upgrades()
  save_game()
end

local function draw_buy_shop()
  local x, y = 8, 80
  local w = 200
  local gap = 6

  local items = {
    { kind = "ghosts",    label = "Ghost" },
    { kind = "accel",     label = "Accel" },
    { kind = "top_speed", label = "Top Speed" },
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

local CHECKPOINT_LABEL_SCALE = 2

local function draw_checkpoint(cp, n, faded)
  local outline_color = gfx.COLOR_DARK_GREEN
  if not faded then
    outline_color = gfx.COLOR_DARK_GRAY
    gfx.rect_fill(cp.x, cp.y, cp.w, cp.h, gfx.COLOR_DARK_GREEN)
  end
  gfx.rect(cp.x, cp.y, cp.w, cp.h, outline_color)

  local label = tostring(n)
  local tw, th = usagi.measure_text(label)
  local tx = math.floor(cp.x + (cp.w - tw * CHECKPOINT_LABEL_SCALE) / 2)
  local ty = math.floor(cp.y + (cp.h - th * CHECKPOINT_LABEL_SCALE) / 2)
  local alpha = faded and GHOST_ALPHA or 1
  gfx.text_ex(label, tx, ty, CHECKPOINT_LABEL_SCALE, 0, gfx.COLOR_BLACK, alpha)
end

local function draw_buy()
  draw_track()
  dim.draw(game_width, game_height)
  for i, cp in ipairs(CHECKPOINTS) do
    draw_checkpoint(cp, i, true)
  end
  draw_sim_ghosts(GHOST_ALPHA)
  draw_cash_pops()
  draw_money()
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

---Draw the checkpoints still ahead this lap: the active one solid, future ones
---faded. Already-hit checkpoints are skipped so the player only sees what's
---left to chase.
local function draw_checkpoints()
  local active = State.race.next_checkpoint
  for i = active, #CHECKPOINTS do
    draw_checkpoint(CHECKPOINTS[i], i, i ~= active)
  end
end

local function draw_race_result()
  dim.draw(game_width, game_height)
  local race = State.race

  local function centered(text, y, scale, color)
    local tw = usagi.measure_text(text) * scale
    local x = math.floor((game_width - tw) / 2)
    gfx.text_ex(text, x, y, scale, 0, color or gfx.COLOR_WHITE, 1)
  end

  if race.improved and race.time_delta and race.rate_delta then
    local y = 100
    centered(string.format("-%.2fs", race.time_delta), y, 3, gfx.COLOR_GREEN)
    y = y + 30
    centered(string.format("+$%.2f/sec", race.rate_delta), y, 3, gfx.COLOR_GREEN)
    y = y + 50
    local bw = 200
    if ui.button("CONTINUE", math.floor((game_width - bw) / 2), y + 10, { w = bw, scale = 3 }) then
      return_to_buy()
    end
  else
    return_to_buy()
  end
end

local function draw_race()
  draw_track()

  local race = State.race
  if race.phase ~= "result" then
    draw_checkpoints()
  end

  draw_skid_marks()
  draw_sim_ghosts(GHOST_RACE_ALPHA)
  draw_race_ghost()
  draw_car()
  draw_cash_pops()
  draw_money()

  if race.phase == "countdown" then
    draw_countdown()
  elseif race.phase == "result" then
    draw_race_result()
  else
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
