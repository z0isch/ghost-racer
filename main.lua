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

-- Coins are single-tile pickups sprinkled on the track. Like checkpoints they
-- pay the player more live than a ghost banks idle, and they respawn every lap
-- / ghost loop. COIN_SPRITE is the 1-based sprite-sheet index.
local COIN_PAY = 10      -- $ credited live when the player drives over a coin
local GHOST_COIN_PAY = 3 -- $ a ghost banks each time its loop crosses a coin
local COIN_SPRITE = 4
local COIN_ICON = "©"
-- Coins have no in-text glyph: UI conveys "this is coins" by drawing the number
-- in COLOR_YELLOW (cash uses COLOR_DARK_GREEN). The world pickups draw COIN_SPRITE.
local COIN_BOB_AMP = .6 -- pixels of vertical sine bob (visual only)
local COIN_BOB_HZ = 1.5 -- bob cycles per second

-- Car stats derive from upgrade levels at race start: base + level * step.
local ACCEL_BASE, ACCEL_STEP = 50, 15
local TOP_VEL_BASE, TOP_VEL_STEP = 200, 30

-- Geometric cost curve per upgrade: cost(level) = base_cost * growth^level,
-- capped at `max`. The ghost upgrade overrides level 0 -> 1 to be FREE.
local UPGRADES = {
  ghosts    = { max = 8, base_cost = 75, growth = 1.55, currency = "cash" },
  accel     = { max = 5, base_cost = 90, growth = 1.7, currency = "coin" },
  top_speed = { max = 5, base_cost = 90, growth = 1.7, currency = "coin" },
  -- `coins` activates one more coin from the COINS table per level (max set
  -- below to the table length). The map starts with zero coins.
  coins     = { max = 0, base_cost = 60, growth = 1.6, currency = "cash" },
}

local CHECKPOINTS = {
  { x = 560, y = 96, w = 80, h = 176 },
  { x = 0,   y = 96, w = 80, h = 176 },
}

-- Coins, in tile coords. Each occupies one tile; pixel rect is derived. The
-- `coins` upgrade activates these in order, so position [1] is the first coin a
-- player can buy, [2] the second, and so on.
local COINS = {
  { col = 18, row = 7 },
  { col = 34, row = 12 },
  { col = 10, row = 16 }
}

-- The coins upgrade caps at the number of authored coin positions.
UPGRADES.coins.max = #COINS

---Pixel-space hit rect for a coin tile.
local function coin_rect(coin)
  return { x = coin.col * tile_size, y = coin.row * tile_size, w = tile_size, h = tile_size }
end

---How many coins are live on the map: the coins upgrade level. Coins activate
---in COINS order, so this is also the count of leading entries that are active.
local function active_coin_count()
  return State.upgrades.coins or 0
end

local GHOST_ALPHA = 0.6
-- Economy ghosts stay on screen during a race but fade way back so they don't
-- fight the player car or the synced rival ghost for attention.
local GHOST_RACE_ALPHA = 0.03

-- Seconds a ghost holds at the end of its recorded lap before looping back to
-- the start -- a small breather so the loop point reads as a lap, not a jump.
local GHOST_LAP_PAUSE = 0.6

local PAR_TIME = 10.0  -- designer par lap in seconds; 1.0× break-even (tune from playtests)
local SPEED_MULT_P = 2 -- punchiness exponent

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

-- Precomputed coin pickups along ghost_line: one {t, x, y} per coin the lap
-- actually drove over (first overlap, rising edge). Coins the lap never touched
-- are absent, so the ghost replays exactly the coins the player grabbed.
local ghost_coin_pickups = nil

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

---Scan a recorded line for the first pass over each coin (rising-edge overlap),
---returning a {t, x, y} pickup per coin the lap actually touched. Coins the lap
---never overlaps are omitted. Same rect_overlap test as the live player pickup,
---so the ghost's pickups match what the player grabbed on the recorded lap.
local function compute_coin_pickups(line)
  if not line or #line == 0 then return nil end
  local pickups = {}
  for ci = 1, active_coin_count() do
    local rect = coin_rect(COINS[ci])
    local inside_prev = util.rect_overlap(
      { x = line[1].x, y = line[1].y, w = CAR_SIZE, h = CAR_SIZE }, rect)
    for _, s in ipairs(line) do
      local inside = util.rect_overlap({ x = s.x, y = s.y, w = CAR_SIZE, h = CAR_SIZE }, rect)
      if inside and not inside_prev then
        pickups[#pickups + 1] = { t = s.t, x = rect.x + tile_size / 2, y = rect.y }
        break
      end
      inside_prev = inside
    end
  end
  return pickups
end

---Rebuild ghost replay state derived from the current ghost_line.
local function rebuild_ghost_sim()
  ghost_cp_crossings = compute_cp_crossings(State.ghost_line)
  ghost_coin_pickups = compute_coin_pickups(State.ghost_line)
  ghost_prev_phase = {}
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

local function default_state()
  return {
    mode = "buy",
    money = 0,
    coins = 0,
    upgrades = { ghosts = 0, accel = 0, top_speed = 0, coins = 0 },
    ghost_line = nil,
    best_time = nil,
    race = { next_checkpoint = 1, time = 0, phase = "countdown", earned = 0, coins_earned = 0, coins_collected = {} },
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
    coins = State.coins,
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
    State.coins = loaded.coins or 0
    if loaded.upgrades then
      State.upgrades.ghosts = loaded.upgrades.ghosts or 0
      State.upgrades.accel = loaded.upgrades.accel or 0
      State.upgrades.top_speed = loaded.upgrades.top_speed or 0
      -- Clamp to the authored coin count in case the table shrank since saving.
      State.upgrades.coins = math.min(loaded.upgrades.coins or 0, #COINS)
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

---Ghost cash ($/sec) for a recorded lap: checkpoints only.
---@param line table|nil
---@return number
local function lap_cash_rate(line)
  if not line or #line == 0 then return 0 end
  local period = line[#line].t + GHOST_LAP_PAUSE
  if period <= 0 then return 0 end
  return #CHECKPOINTS * GHOST_CHECKPOINT_PAY / period
end

---Ghost coin (coins/sec) for a recorded lap: coin pickups only.
---@param line table|nil
---@return number
local function lap_coin_rate(line)
  if not line or #line == 0 then return 0 end
  local period = line[#line].t + GHOST_LAP_PAUSE
  if period <= 0 then return 0 end
  local pickups = compute_coin_pickups(line)
  local coin_count = pickups and #pickups or 0
  return coin_count * GHOST_COIN_PAY / period
end

---Speed multiplier for a given lap time: (PAR_TIME/t)^P, clamped to [1, inf).
local function speed_mult_from_time(t)
  if not t or t <= 0 then return 1.0 end
  return math.max(1.0, (PAR_TIME / t) ^ SPEED_MULT_P)
end

---Speed multiplier for the current promoted best lap.
local function speed_mult()
  return speed_mult_from_time(State.best_time)
end

---Total idle $/sec from the ghost economy.
local function ghost_cash_rate()
  return State.upgrades.ghosts * lap_cash_rate(State.ghost_line) * speed_mult()
end

---Total idle coins/sec from the ghost economy.
local function ghost_coin_rate()
  return State.upgrades.ghosts * lap_coin_rate(State.ghost_line) * speed_mult()
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
  State.race = { next_checkpoint = 1, time = 0, phase = "countdown", earned = 0, coins_earned = 0, coins_collected = {} }
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

---Promote the current run as the new ghost line and best time.
local function promote_run()
  State.ghost_line = run_samples
  State.best_time = State.race.run_time
  rebuild_ghost_sim()
  save_game()
end

---Finalize a completed race: stash comparison data for the result screen.
---Promotion is now the player's choice — no auto-promote here.
local function finish_race()
  local race                 = State.race
  race.phase                 = "result"
  race.run_time              = race.time

  local has_baseline         = State.ghost_line ~= nil
  race.has_baseline          = has_baseline
  race.run_cash_rate         = lap_cash_rate(run_samples)
  race.run_coin_rate         = lap_coin_rate(run_samples)
  race.run_mult              = speed_mult_from_time(race.run_time)
  race.ghost_mult            = speed_mult()
  race.result_start_time     = usagi.elapsed
  local ghosts               = State.upgrades.ghosts
  race.run_total_rate        = ghosts * race.run_cash_rate * race.run_mult
  race.ghost_total_rate      = ghost_cash_rate()
  race.run_total_coin_rate   = ghosts * race.run_coin_rate * race.run_mult
  race.ghost_total_coin_rate = ghost_coin_rate()

  if has_baseline then
    race.time_delta      = State.best_time - race.time
    race.cash_rate_delta = race.run_total_rate - race.ghost_total_rate
    race.coin_rate_delta = race.run_total_coin_rate - race.ghost_total_coin_rate
  end
end

-- ---------------------------------------------------------------------------
-- Update
-- ---------------------------------------------------------------------------

---Bank any events (checkpoints or coins) whose recorded time falls in the loop
---window (prev, phase], paying `pay` each and spawning a dim ghost pop. Handles
---the wrap when the ghost loops past the end of the line this frame.
local function bank_ghost_events(events, pay, currency, prev, phase)
  for _, e in ipairs(events) do
    local crossed
    if phase >= prev then
      crossed = e.t > prev and e.t <= phase
    else
      -- Looped past the end of the line this frame.
      crossed = e.t > prev or e.t <= phase
    end
    if crossed then
      if currency == "coin" then
        State.coins = State.coins + pay
      else
        State.money = State.money + pay
      end
      cash_pops[#cash_pops + 1] = {
        amount = pay,
        currency = currency,
        x = e.x,
        y = e.y,
        age = 0,
        ghost = true,
        -- Fade race-mode ghost pops to sit alongside the faded ghosts.
        alpha_mul = State.mode == "race" and 0.1 or 1,
      }
    end
  end
end

---Advance the ghost economy one frame. Every owned ghost loops the recorded
---line and banks GHOST_CHECKPOINT_PAY per checkpoint crossing and GHOST_COIN_PAY
---per coin pickup, spawning a dim "+$N" pop at each recorded spot. Runs in both
---modes so idle income never stalls; in race mode the pop fades way back to
---match the faded ghosts.
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
      local mult = speed_mult()
      bank_ghost_events(ghost_cp_crossings, GHOST_CHECKPOINT_PAY * mult, "cash", prev, phase)
      if ghost_coin_pickups then
        bank_ghost_events(ghost_coin_pickups, GHOST_COIN_PAY * mult, "coin", prev, phase)
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
    countdown_time = countdown_time - (dt * 2)
    if countdown_time <= 0 then
      countdown_time = 0
      race.phase = "racing"
    end
  elseif race.phase == "racing" then
    update_car(dt)

    -- Live coin pickups: each coin pays once per lap. Collected coins are
    -- tracked per-race and reset next lap (coins respawn each loop).
    local car_rect = { x = car.x, y = car.y, w = CAR_SIZE, h = CAR_SIZE }
    for ci = 1, active_coin_count() do
      local coin = COINS[ci]
      if not race.coins_collected[ci] and util.rect_overlap(car_rect, coin_rect(coin)) then
        race.coins_collected[ci] = true
        State.coins = State.coins + COIN_PAY
        race.coins_earned = race.coins_earned + COIN_PAY
        sfx.play("coin")
        cash_pops[#cash_pops + 1] = {
          amount = COIN_PAY,
          currency = "coin",
          x = coin.col * tile_size + tile_size / 2,
          y = coin.row * tile_size,
          age = 0,
        }
      end
    end

    -- Live per-checkpoint crediting against the single active checkpoint.
    local cp = CHECKPOINTS[race.next_checkpoint]
    if cp then
      if util.rect_overlap(car_rect, cp) then
        State.money = State.money + CHECKPOINT_PAY
        race.earned = race.earned + CHECKPOINT_PAY
        cash_pops[#cash_pops + 1] = {
          amount = CHECKPOINT_PAY,
          currency = "cash",
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

---Draw the coins as bobbing sprites. `collected`, when given (race mode), hides
---coins the player already grabbed this lap; in buy mode all coins draw since
---they're the live income layer. The bob is purely visual -- pickup uses the
---fixed tile rect.
local function draw_coins(collected)
  local bob = math.sin(usagi.elapsed * COIN_BOB_HZ * 2 * math.pi) * COIN_BOB_AMP
  for ci = 1, active_coin_count() do
    if not (collected and collected[ci]) then
      local coin = COINS[ci]
      gfx.spr(COIN_SPRITE, coin.col * tile_size, coin.row * tile_size + bob)
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

---Draw the HUD currency readouts: cash ($/bal + $/sec) left-aligned,
---coins (sprite + bal + coins/sec) right-aligned.
local function draw_hud_currencies()
  local scale          = 3
  local _, th          = usagi.measure_text("0")
  local bal_y          = 6
  local rate_y         = bal_y + th * scale + 3
  local gap            = 24 -- pixels between the two centered currency columns

  -- Cash column (blue): balance + rate.
  local money_text     = string.format("$%.0f", State.money)
  local cash_rate_text = string.format("%.2f $/sec", ghost_cash_rate())
  local cash_w         = math.max(usagi.measure_text(money_text) * scale,
    usagi.measure_text(cash_rate_text))

  -- Coin column (yellow): balance + rate.
  local coin_text      = string.format(COIN_ICON .. "%.0f", State.coins)
  local coin_rate_text = string.format("%.2f " .. COIN_ICON .. "/sec", ghost_coin_rate())
  local coin_w         = math.max(usagi.measure_text(coin_text) * scale,
    usagi.measure_text(coin_rate_text))

  -- Center the two columns side by side around the screen midpoint.
  local cash_x         = (game_width - (cash_w + gap + coin_w)) / 2
  local coin_x         = cash_x + cash_w + gap

  gfx.text_ex(money_text, cash_x, bal_y, scale, 0, gfx.COLOR_DARK_GREEN, 1)
  gfx.text_ex(cash_rate_text, cash_x, rate_y, 1, 0, gfx.COLOR_DARK_GREEN, 1)

  gfx.text_ex(coin_text, coin_x, bal_y, scale, 0, gfx.COLOR_YELLOW, 1)
  gfx.text_ex(coin_rate_text, coin_x, rate_y, 1, 0, gfx.COLOR_YELLOW, 1)
end

---Draw the floating popups rising and fading. Currency is shown by color, not a
---glyph: cash pops blue, coin pops yellow. Player pops bold (scale 2); ghost
---pops dim/small.
local function draw_cash_pops()
  for _, p in ipairs(cash_pops) do
    local t     = p.age / CASH_POP_LIFE
    local scale = p.ghost and 1 or 2
    local alpha = (1 - t) * (p.ghost and 0.6 or 1) * (p.alpha_mul or 1)
    local py    = p.y - t * CASH_POP_RISE

    local color = gfx.COLOR_DARK_GREEN
    if p.currency == "coin" then
      color = gfx.COLOR_YELLOW
    end
    local text = string.format("%.0f", p.amount)
    local tw   = usagi.measure_text(text) * scale
    local px   = math.floor(p.x - tw / 2)
    gfx.text_ex(text, px, py, scale, 0, color, alpha)
  end
end

local function draw_countdown()
  dim.draw(game_width, game_height)
  local text = tostring(math.ceil(countdown_time))
  local scale = 12
  local tw, th = usagi.measure_text(text)
  local x = math.floor((game_width - tw * scale) / 2)
  local y = math.floor((game_height - th * scale) / 2)
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
  local currency = UPGRADES[kind].currency

  local cost_text
  local cost_color -- nil for MAX/FREE -> button uses its default text color
  if cost == nil then
    cost_text = "MAX"
  elseif cost == 0 then
    cost_text = "FREE"
  elseif currency == "coin" then
    cost_text = COIN_ICON .. tostring(cost)
    cost_color = gfx.COLOR_WHITE
  else
    cost_text = "$" .. tostring(cost)
    cost_color = gfx.COLOR_WHITE
  end

  local balance = currency == "coin" and State.coins or State.money
  local affordable = cost ~= nil and (cost == 0 or balance >= cost)
  if kind == "ghosts" and not State.ghost_line then affordable = false end

  local _, th = usagi.measure_text(label)
  local bh = th * 2 + 4

  ui.label(label, x, y + math.floor((bh - th * 2) / 2))

  -- Currency is conveyed by the cost color (blue = cash, yellow = coin) rather
  -- than a glyph; MAX/FREE leave cost_color nil so the button uses its default.
  local bx = x + w - SHOP_COST_W
  local clicked = ui.button(cost_text, bx, y, { w = SHOP_COST_W, disabled = not affordable, text = cost_color })
  return clicked, bh
end

local function try_buy(kind)
  local cost = upgrade_cost(kind)
  if cost == nil then return end
  if kind == "ghosts" and not State.ghost_line then return end
  local currency = UPGRADES[kind].currency
  local balance = currency == "coin" and State.coins or State.money
  if cost > 0 and balance < cost then return end
  if currency == "coin" then
    State.coins = State.coins - cost
  else
    State.money = State.money - cost
  end
  State.upgrades[kind] = State.upgrades[kind] + 1
  -- Buying a ghost changes N, so the staggered offsets shift: reset phase
  -- tracking to avoid spurious crossings the frame the count changes.
  if kind == "ghosts" then ghost_prev_phase = {} end
  -- Buying a coin activates another COINS entry, so the ghost's recorded coin
  -- pickups (and the $/sec readout) need recomputing against the new set.
  if kind == "coins" then rebuild_ghost_sim() end
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
    { kind = "coins",     label = "Coin" },
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
  draw_coins()
  draw_sim_ghosts(GHOST_ALPHA)
  draw_cash_pops()
  draw_hud_currencies()
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

  local function centered_text(text, y, scale, color)
    local tw = usagi.measure_text(text) * scale
    local x  = math.floor((game_width - tw) / 2)
    gfx.text_ex(text, x, y, scale, 0, color or gfx.COLOR_WHITE, 1)
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

  -- A rate delta line: the value (with +/- sign) in its green/red delta color,
  -- the "/sec" unit in the currency color (blue = cash, yellow = coin). Both
  -- segments are measured so the pair lands centered.
  local function centered_rate_delta(value_text, unit_text, value_color, unit_color, y, scale)
    local vw = usagi.measure_text(value_text) * scale
    local uw = usagi.measure_text(unit_text) * scale
    local x  = math.floor((game_width - (vw + uw)) / 2)
    gfx.text_ex(value_text, x, y, scale, 0, value_color, 1)
    gfx.text_ex(unit_text, x + vw, y, scale, 0, unit_color, 1)
  end

  local y = 80

  if race.has_baseline then
    local time_col = delta_color(race.time_delta)
    local sign = "+"
    if race.time_delta >= 0 then sign = "-" end
    centered_text(string.format("%s%.2fs", sign, math.abs(race.time_delta)), y, 2, time_col)
    y               = y + 22

    local cash_col  = delta_color(race.cash_rate_delta)
    local cash_sign = race.cash_rate_delta >= 0 and "+" or ""
    centered_rate_delta(string.format("%s%.2f", cash_sign, race.cash_rate_delta), " $/sec", cash_col,
      gfx.COLOR_DARK_GREEN, y,
      2)
    y               = y + 22

    local coin_col  = delta_color(race.coin_rate_delta)
    local coin_sign = race.coin_rate_delta >= 0 and "+" or ""
    centered_rate_delta(string.format("%s%.2f", coin_sign, race.coin_rate_delta), " " .. COIN_ICON .. "/sec", coin_col,
      gfx.COLOR_YELLOW, y,
      2)
    y = y + 34

    local bw = 150
    local gap = 8
    local lx = math.floor((game_width - bw * 2 - gap) / 2)
    if ui.button("USE THIS RUN", lx, y, { w = bw, scale = 2 }) then
      promote_run()
      return_to_buy()
    end
    if ui.button("KEEP CURRENT", lx + bw + gap, y, { w = bw, scale = 2 }) then
      return_to_buy()
    end
  else
    -- First run: show mult and absolutes, force promotion.
    centered_text(string.format("Time %.2fs", race.run_time), y, 2, gfx.COLOR_WHITE)
    y = y + 22
    centered_text(string.format("%.2f/sec", race.run_cash_rate), y, 2, gfx.COLOR_WHITE)
    y = y + 22
    centered_text(string.format("%.2f/sec", race.run_coin_rate), y, 2, gfx.COLOR_WHITE)
    y = y + 34

    local bw = 180
    if ui.button("USE THIS RUN", math.floor((game_width - bw) / 2), y, { w = bw, scale = 2 }) then
      promote_run()
      return_to_buy()
    end
  end
end

local function draw_race()
  draw_track()

  local race = State.race
  if race.phase ~= "result" then
    draw_checkpoints()
  end

  draw_coins(race.coins_collected)
  draw_skid_marks()
  draw_sim_ghosts(GHOST_RACE_ALPHA)
  draw_race_ghost()
  draw_car()
  draw_cash_pops()
  draw_hud_currencies()

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
