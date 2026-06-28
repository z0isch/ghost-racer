local basic_map = require "tile-map.basic"
local track2 = require "tile-map.track2"
local ui = require "ui"
local dim = require "dim"

local game_width = 640
local game_height = 352

local tile_size = basic_map.tilewidth

local tile_colors = {
  [0] = gfx.COLOR_DARK_BLUE,
  [1] = gfx.COLOR_INDIGO,
  [2] = gfx.COLOR_BLACK,
  [3] = gfx.COLOR_WHITE
}

local CAR_SIZE = 16
local CAR_MARGIN = 3

-- ---------------------------------------------------------------------------
-- Track definitions
-- ---------------------------------------------------------------------------

local TRACKS = {
  basic = {
    map         = basic_map,
    spawn       = { col = 1, row = 9 },
    checkpoints = {
      { col = 35, row = 6, w = 4, h = 11 },
      { col = 1,  row = 6, w = 4, h = 11 },
    },
    coins       = {
      { col = 18, row = 7 },
      { col = 34, row = 12 },
      { col = 10, row = 16 },
    },
    par         = 10.0,
    label       = "Track 1",
    unlock_cost = nil,
    shop        = {
      {
        kind = "ghosts",
        label = "Ghost",
        currency = "cash",
        max = 8,
        base_cost = 75,
        growth = 1.55
      },
      {
        kind = "coins",
        label = "Add a Coin",
        currency = "cash",
        base_cost = 60,
        growth = 1.6
      },
      {
        kind = "accel",
        label = "Accel",
        currency = "coin",
        max = 5,
        base_cost = 180,
        growth = 1.7
      },
    },
  },
  track2 = {
    map         = track2,
    spawn       = { col = 7, row = 3 },
    checkpoints = {
      { col = 34, row = 6,  w = 5, h = 4 },
      { col = 10, row = 14, w = 7, h = 2 },
      { col = 1,  row = 1,  w = 5, h = 5 },

    },
    coins       = {
      { col = 18, row = 7 },
      { col = 34, row = 12 },
      { col = 10, row = 16 },
    },
    par         = 10.0,
    label       = "Track 2",
    unlock_cost = 500,
    shop        = {
      {
        kind = "ghosts",
        label = "Ghost",
        currency = "cash",
        max = 8,
        base_cost = 75,
        growth = 1.55
      },
      {
        kind = "coins",
        label = "Add a Coin",
        currency = "cash",
        base_cost = 120,
        growth = 1.6
      },
      {
        kind = "top_speed",
        label = "Top Speed",
        currency = "coin",
        max = 5,
        base_cost = 180,
        growth = 1.7
      },
    },
  },
}

local TRACK_ORDER = { "basic", "track2" }

-- The shop config (currency/max/base_cost/growth) for `kind` on a given track,
-- or nil if that track's shop doesn't offer it.
local function track_shop_item(track_id, kind)
  for _, item in ipairs(TRACKS[track_id].shop) do
    if item.kind == kind then return item end
  end
  return nil
end

-- Max level for `kind`, searched across every track's shop. Used by save
-- migration to clamp loaded levels (accel/top_speed live in one track's shop;
-- ghosts in all). Returns nil for kinds with no fixed max (e.g. coins).
local function kind_max(kind)
  for _, tid in ipairs(TRACK_ORDER) do
    local item = track_shop_item(tid, kind)
    if item then return item.max end
  end
  return nil
end

local function get_track_index(id)
  for i, tid in ipairs(TRACK_ORDER) do
    if tid == id then return i end
  end
  return 1
end

-- ---------------------------------------------------------------------------
-- Economy / upgrade tuning
-- ---------------------------------------------------------------------------

local CHECKPOINT_PAY = 25
local GHOST_CHECKPOINT_PAY = 8
local COIN_PAY = 10
local GHOST_COIN_PAY = 3
local COIN_SPRITE = 4
local COIN_ICON = "©"
local COIN_BOB_AMP = .6
local COIN_BOB_HZ = 1.5

local ACCEL_BASE, ACCEL_STEP = 50, 15
local TOP_VEL_BASE, TOP_VEL_STEP = 200, 30

-- BTN3 overspeed boost: an instant velocity impulse that pushes vel past
-- top_vel, then gently bleeds back to the cap. Gated by per-race charges
-- (refilled in reset_car). MAX_BOOSTS is a hardcoded capacity for now; buying
-- more is a deferred follow-up.
local MAX_BOOSTS = 10
local OVERSPEED_IMPULSE = 100
local OVERSPEED_DECAY = 100
local BOOST_FLAME_TIME = 0.8

-- ghosts/coins are per-track; accel/top_speed upgrade the global car but are
-- purchase-gated per track (accel in Track 1, top_speed in Track 2). Each item's
-- cost/scaling (currency, max, base_cost, growth) lives on its TRACKS[id].shop
-- entry. The `coins` item has no max; its real cap is #TRACKS[id].coins, applied
-- in upgrade_cost.

local GHOST_ALPHA = 0.6
local GHOST_RACE_ALPHA = 0.03
local GHOST_LAP_PAUSE = 0.6

local PAR_TIME = 10.0
local SPEED_MULT_P = 2

-- ---------------------------------------------------------------------------
-- Engine entrypoints
-- ---------------------------------------------------------------------------

function _config()
  return {
    name        = "Usagi Test",
    game_id     = "com.usagi.drift",
    game_width  = game_width,
    game_height = game_height,
  }
end

-- ---------------------------------------------------------------------------
-- Transient runtime state
-- ---------------------------------------------------------------------------

local skid_marks     = {}
local skid_prev      = nil
local cash_pops      = {}
local CASH_POP_LIFE  = 1.5
local CASH_POP_RISE  = 50

local car            = {
  x = 0,
  y = 0,
  vel = 0,
  top_vel = TOP_VEL_BASE,
  facing_angle = 0,
  vel_angle = 0,
  turn_speed = 0.03,
  drift_turn_speed = 0.06,
  drift_slide = math.pi / 8,
  drift_deccel = 100,
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
  boosts = MAX_BOOSTS,
  boost_flame_t = 0,
}

local run_samples    = {}
local countdown_time = 0
local sim_time       = 0

-- Per-track ghost simulation state: crossings, pickups, prev phase.
local track_sim      = {}

local function get_track_sim(id)
  if not track_sim[id] then
    track_sim[id] = { ghost_prev_phase = {}, ghost_cp_crossings = nil, ghost_coin_pickups = nil }
  end
  return track_sim[id]
end

-- ---------------------------------------------------------------------------
-- Tile / road helpers
-- ---------------------------------------------------------------------------

local function get_tile(x, y)
  local m     = TRACKS[State.active_track].map
  local layer = m.layers[1].data
  local mw    = m.width
  local mh    = m.height
  local col   = math.floor(x / tile_size)
  local row   = math.floor(y / tile_size)
  if col < 0 or col >= mw or row < 0 or row >= mh then return 0 end
  return layer[row * mw + col + 1]
end

local function is_drivable(tile)
  return tile == 1 or tile == 3
end

local function car_on_road(x, y)
  local inner = CAR_SIZE - CAR_MARGIN - 1
  return is_drivable(get_tile(x + CAR_MARGIN, y + CAR_MARGIN))
      and is_drivable(get_tile(x + inner, y + CAR_MARGIN))
      and is_drivable(get_tile(x + CAR_MARGIN, y + inner))
      and is_drivable(get_tile(x + inner, y + inner))
end

local function coin_rect(coin)
  return { x = coin.col * tile_size, y = coin.row * tile_size, w = tile_size, h = tile_size }
end

-- Checkpoints are stored in tile units (col/row/w/h); this expands one to a
-- pixel-space rect for overlap tests and drawing.
local function checkpoint_rect(cp)
  return {
    x = cp.col * tile_size,
    y = cp.row * tile_size,
    w = cp.w * tile_size,
    h = cp.h * tile_size,
  }
end

local function active_coin_count()
  local id    = State.active_track
  local tdata = TRACKS[id]
  return math.min(State.tracks[id].coins, #tdata.coins)
end

-- ---------------------------------------------------------------------------
-- Ghost sim precomputation
-- ---------------------------------------------------------------------------

local function compute_cp_crossings(line, checkpoints)
  if not line or #line == 0 then return nil end
  local crossings = {}
  for ci, cp in ipairs(checkpoints) do
    local rect        = checkpoint_rect(cp)
    local inside_prev = util.rect_overlap(
      { x = line[1].x, y = line[1].y, w = CAR_SIZE, h = CAR_SIZE }, rect)
    for _, s in ipairs(line) do
      local inside = util.rect_overlap({ x = s.x, y = s.y, w = CAR_SIZE, h = CAR_SIZE }, rect)
      if inside and not inside_prev then
        crossings[ci] = { t = s.t, x = s.x + CAR_SIZE / 2, y = s.y }
        break
      end
      inside_prev = inside
    end
    if not crossings[ci] then
      crossings[ci] = { t = 0, x = rect.x + rect.w / 2, y = rect.y + rect.h / 2 }
    end
  end
  return crossings
end

local function compute_coin_pickups(line, coins, coin_count)
  if not line or #line == 0 then return nil end
  local pickups = {}
  for ci = 1, coin_count do
    local rect        = coin_rect(coins[ci])
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

local function rebuild_ghost_sim(id)
  local ts              = get_track_sim(id)
  local tstate          = State.tracks[id]
  local tdata           = TRACKS[id]
  ts.ghost_cp_crossings = compute_cp_crossings(tstate.ghost_line, tdata.checkpoints)
  ts.ghost_coin_pickups = compute_coin_pickups(tstate.ghost_line, tdata.coins, tstate.coins)
  ts.ghost_prev_phase   = {}
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

local function default_track_state(id)
  return {
    ghost_line = nil,
    best_time  = nil,
    par        = TRACKS[id].par,
    ghosts     = 0,
    coins      = 0,
  }
end

local function default_state()
  return {
    mode         = "buy",
    money        = 100000,
    coins        = 100000,
    accel        = 0,
    top_speed    = 0,
    active_track = "basic",
    unlocked     = { basic = true },
    tracks       = { basic = default_track_state("basic") },
    race         = {
      next_checkpoint = 1,
      time = 0,
      phase = "countdown",
      earned = 0,
      coins_earned = 0,
      coins_collected = {},
    },
  }
end

local function apply_car_upgrades()
  car.accel   = ACCEL_BASE + State.accel * ACCEL_STEP
  car.top_vel = TOP_VEL_BASE + State.top_speed * TOP_VEL_STEP
end

local function save_game()
  usagi.save({
    money        = State.money,
    coins        = State.coins,
    accel        = State.accel,
    top_speed    = State.top_speed,
    active_track = State.active_track,
    unlocked     = State.unlocked,
    tracks       = State.tracks,
  })
end

function _init()
  local loaded = usagi.load()
  State = default_state()
  if loaded then
    State.money         = loaded.money or 0
    State.coins         = loaded.coins or 0
    -- Migrate old save format (had nested upgrades table instead of flat accel/top_speed)
    local old_accel     = loaded.upgrades and loaded.upgrades.accel or 0
    local old_top_speed = loaded.upgrades and loaded.upgrades.top_speed or 0
    State.accel         = math.min(loaded.accel or old_accel, kind_max("accel"))
    State.top_speed     = math.min(loaded.top_speed or old_top_speed, kind_max("top_speed"))

    if loaded.active_track and TRACKS[loaded.active_track] then
      State.active_track = loaded.active_track
    end

    if loaded.unlocked then
      for id, v in pairs(loaded.unlocked) do
        if TRACKS[id] then
          State.unlocked[id] = v
          if v and not State.tracks[id] then
            State.tracks[id] = default_track_state(id)
          end
        end
      end
    end

    if loaded.tracks then
      for id, lt in pairs(loaded.tracks) do
        if TRACKS[id] then
          if not State.tracks[id] then
            State.tracks[id] = default_track_state(id)
          end
          local ts      = State.tracks[id]
          local tdata   = TRACKS[id]
          ts.ghost_line = lt.ghost_line
          ts.best_time  = lt.best_time
          ts.ghosts     = math.min(lt.ghosts or 0, kind_max("ghosts"))
          ts.coins      = math.min(lt.coins or 0, #tdata.coins)
        end
      end
    else
      -- Migrate old single-track save (no tracks table)
      if loaded.ghost_line then
        State.tracks.basic.ghost_line = loaded.ghost_line
        State.tracks.basic.best_time  = loaded.best_time
      end
      if loaded.upgrades then
        State.tracks.basic.ghosts = math.min(loaded.upgrades.ghosts or 0, kind_max("ghosts"))
        State.tracks.basic.coins  = math.min(loaded.upgrades.coins or 0, #TRACKS.basic.coins)
      end
    end
  end
  State.mode = "buy"
  apply_car_upgrades()
  for id, _ in pairs(State.unlocked) do
    rebuild_ghost_sim(id)
  end
end

-- ---------------------------------------------------------------------------
-- Economy helpers
-- ---------------------------------------------------------------------------

local function upgrade_cost(kind)
  local id = State.active_track
  local u  = track_shop_item(id, kind)
  if not u then return nil end
  local lvl
  if kind == "ghosts" or kind == "coins" then
    lvl = State.tracks[id][kind]
  else
    lvl = State[kind]
  end
  local max = u.max
  if kind == "coins" then max = #TRACKS[id].coins end
  if lvl >= max then return nil end
  if kind == "ghosts" and lvl == 0 then return 0 end
  return math.floor(u.base_cost * (u.growth ^ lvl))
end

-- ---------------------------------------------------------------------------
-- Angle / replay math
-- ---------------------------------------------------------------------------

local function nomalize_angle(angle)
  return angle - 2 * math.pi * math.floor(angle / (2 * math.pi))
end

local function lerp_angle(a, b, t)
  local diff = b - a
  diff = diff - 2 * math.pi * math.floor((diff + math.pi) / (2 * math.pi))
  return a + diff * math.min(t, 1)
end

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
      local t    = 0
      if span > 0 then t = (time - a.t) / span end
      return {
        x     = util.lerp(a.x, b.x, t),
        y     = util.lerp(a.y, b.y, t),
        angle = lerp_angle(a.angle, b.angle, t),
        drift = a.drift,
      }
    end
  end
  return last
end

local function ghost_loop_period(line)
  if not line or #line == 0 then return 0 end
  return line[#line].t + GHOST_LAP_PAUSE
end

local function speed_mult_from_time(t)
  if not t or t <= 0 then return 1.0 end
  return math.max(1.0, (PAR_TIME / t) ^ SPEED_MULT_P)
end

-- Per-track income rates.
local function track_cash_rate(id)
  local tstate = State.tracks[id]
  if not tstate or not tstate.ghost_line then return 0 end
  local line   = tstate.ghost_line
  local period = line[#line].t + GHOST_LAP_PAUSE
  if period <= 0 then return 0 end
  local tdata = TRACKS[id]
  return tstate.ghosts
      * (#tdata.checkpoints * GHOST_CHECKPOINT_PAY / period)
      * speed_mult_from_time(tstate.best_time)
end

local function track_coin_rate(id)
  local tstate = State.tracks[id]
  if not tstate or not tstate.ghost_line then return 0 end
  local line   = tstate.ghost_line
  local period = line[#line].t + GHOST_LAP_PAUSE
  if period <= 0 then return 0 end
  local tdata   = TRACKS[id]
  local pickups = compute_coin_pickups(line, tdata.coins, tstate.coins)
  local count   = pickups and #pickups or 0
  return tstate.ghosts
      * (count * GHOST_COIN_PAY / period)
      * speed_mult_from_time(tstate.best_time)
end

-- Total across all unlocked tracks.
local function ghost_cash_rate()
  local total = 0
  for id, v in pairs(State.unlocked) do
    if v and State.tracks[id] then total = total + track_cash_rate(id) end
  end
  return total
end

local function ghost_coin_rate()
  local total = 0
  for id, v in pairs(State.unlocked) do
    if v and State.tracks[id] then total = total + track_coin_rate(id) end
  end
  return total
end

-- Active-track lap rates (used in the race result screen).
local function lap_cash_rate(line)
  if not line or #line == 0 then return 0 end
  local period = line[#line].t + GHOST_LAP_PAUSE
  if period <= 0 then return 0 end
  local tdata = TRACKS[State.active_track]
  return #tdata.checkpoints * GHOST_CHECKPOINT_PAY / period
end

local function lap_coin_rate(line)
  if not line or #line == 0 then return 0 end
  local period = line[#line].t + GHOST_LAP_PAUSE
  if period <= 0 then return 0 end
  local tdata   = TRACKS[State.active_track]
  local tstate  = State.tracks[State.active_track]
  local pickups = compute_coin_pickups(line, tdata.coins, tstate.coins)
  local count   = pickups and #pickups or 0
  return count * GHOST_COIN_PAY / period
end

-- ---------------------------------------------------------------------------
-- Car physics + recording
-- ---------------------------------------------------------------------------

local function reset_car()
  local spawn              = TRACKS[State.active_track].spawn
  car.x                    = spawn.col * tile_size
  car.y                    = spawn.row * tile_size
  car.vel                  = 0
  car.facing_angle         = 0
  car.vel_angle            = 0
  car.is_drifitng          = false
  car.drift_time           = 0
  car.boost_ready          = false
  car.boost_time_remaining = 0
  car.boosts               = MAX_BOOSTS
  car.boost_flame_t        = 0
  skid_marks               = {}
  skid_prev                = nil
  cash_pops                = {}
end

local function update_car(dt)
  local holding_left  = input.held(input.LEFT)
  local holding_right = input.held(input.RIGHT)
  local is_drifitng   = false
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
  local new_x   = util.clamp(car.x + vel_vec.x, 0, game_width - CAR_SIZE)
  local new_y   = util.clamp(car.y + vel_vec.y, 0, game_height - CAR_SIZE)

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

  if input.pressed(input.BTN3) and car.boosts > 0 then
    car.vel = car.vel + OVERSPEED_IMPULSE
    car.boosts = car.boosts - 1
    car.boost_flame_t = BOOST_FLAME_TIME
  end

  if car.vel > effective_top_vel then
    -- Overspeed (from a BTN3 boost): bleed gently back to the cap regardless of
    -- accelerate input, rather than hard-clamping the impulse away in one frame.
    car.vel = math.max(effective_top_vel, car.vel - OVERSPEED_DECAY * dt)
  elseif input.held(input.BTN1) then
    car.vel = util.clamp(car.vel + car.accel * dt, 0, effective_top_vel)
  else
    car.vel = util.clamp(car.vel - car.deccel * dt, 0, effective_top_vel)
  end

  if is_drifitng then
    -- No upper clamp here so a drift during overspeed bleeds smoothly instead of
    -- snapping straight to top_vel.
    car.vel = math.max(0, car.vel - car.drift_deccel * dt)
  end

  if car.boost_flame_t > 0 then
    car.boost_flame_t = math.max(0, car.boost_flame_t - dt)
  end

  if holding_left or holding_right then
    local turn_speed = car.turn_speed
    if is_drifitng then turn_speed = car.drift_turn_speed end
    local dir = 1
    if holding_left then dir = -1 end
    car.facing_angle = nomalize_angle(
      car.facing_angle + (dir * turn_speed / (1 + car.vel * car.turn_speed_factor)))
  end

  if is_drifitng then
    car.is_drifitng = true
    car.drift_time  = car.drift_time + dt
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
    car.drift_time  = 0
  end

  if car.boost_time_remaining > 0 then
    car.boost_time_remaining = car.boost_time_remaining - dt
  end

  if is_drifitng then
    local cx   = car.x + 8
    local cy   = car.y + 8
    local back = util.vec_from_angle(car.facing_angle + math.pi, 5)
    local perp = util.vec_from_angle(car.facing_angle + math.pi / 2, 4)
    local lx   = cx + back.x - perp.x
    local ly   = cy + back.y - perp.y
    local rx   = cx + back.x + perp.x
    local ry   = cy + back.y + perp.y
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
        age = 0,
      }
      if #skid_marks > car.skid_max_count then table.remove(skid_marks, 1) end
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
    t     = race.time,
    x     = car.x,
    y     = car.y,
    angle = car.facing_angle,
    drift = car.is_drifitng,
  }
end

-- ---------------------------------------------------------------------------
-- Mode transitions
-- ---------------------------------------------------------------------------

local function start_race()
  State.mode = "race"
  State.race = {
    next_checkpoint = 1,
    time = 0,
    phase = "countdown",
    earned = 0,
    coins_earned = 0,
    coins_collected = {},
  }
  run_samples = {}
  apply_car_upgrades()
  reset_car()
  countdown_time = 3
  save_game()
end

local function return_to_buy()
  State.mode = "buy"
  for id, v in pairs(State.unlocked) do
    if v then get_track_sim(id).ghost_prev_phase = {} end
  end
  save_game()
end

local function promote_run()
  local id                    = State.active_track
  State.tracks[id].ghost_line = run_samples
  State.tracks[id].best_time  = State.race.run_time
  rebuild_ghost_sim(id)
  save_game()
end

local function finish_race()
  local race                 = State.race
  local id                   = State.active_track
  local tstate               = State.tracks[id]
  race.phase                 = "result"
  race.run_time              = race.time

  local has_baseline         = tstate.ghost_line ~= nil
  race.has_baseline          = has_baseline
  race.run_cash_rate         = lap_cash_rate(run_samples)
  race.run_coin_rate         = lap_coin_rate(run_samples)
  race.run_mult              = speed_mult_from_time(race.run_time)
  race.ghost_mult            = speed_mult_from_time(tstate.best_time)
  race.result_start_time     = usagi.elapsed
  local ghosts               = tstate.ghosts
  race.run_total_rate        = ghosts * race.run_cash_rate * race.run_mult
  race.ghost_total_rate      = track_cash_rate(id)
  race.run_total_coin_rate   = ghosts * race.run_coin_rate * race.run_mult
  race.ghost_total_coin_rate = track_coin_rate(id)

  if has_baseline then
    race.time_delta      = tstate.best_time - race.time
    race.cash_rate_delta = race.run_total_rate - race.ghost_total_rate
    race.coin_rate_delta = race.run_total_coin_rate - race.ghost_total_coin_rate
  end
end

-- ---------------------------------------------------------------------------
-- Update
-- ---------------------------------------------------------------------------

local function bank_ghost_events(events, pay, currency, prev, phase, spawn_pops)
  for _, e in ipairs(events) do
    local crossed
    if phase >= prev then
      crossed = e.t > prev and e.t <= phase
    else
      crossed = e.t > prev or e.t <= phase
    end
    if crossed then
      if currency == "coin" then
        State.coins = State.coins + pay
      else
        State.money = State.money + pay
      end
      -- Pops are positioned in the active track's map space, so only spawn
      -- them for the active track; other tracks still bank earnings silently.
      if spawn_pops then
        cash_pops[#cash_pops + 1] = {
          amount    = pay,
          currency  = currency,
          x         = e.x,
          y         = e.y,
          age       = 0,
          ghost     = true,
          alpha_mul = State.mode == "race" and 0.1 or 1,
        }
      end
    end
  end
end

local function update_ghost_earnings()
  for _, id in ipairs(TRACK_ORDER) do
    if State.unlocked[id] and State.tracks[id] then
      local tstate = State.tracks[id]
      local count  = tstate.ghosts
      local line   = tstate.ghost_line
      if count > 0 and line then
        local ts = get_track_sim(id)
        if not ts.ghost_cp_crossings then rebuild_ghost_sim(id) end
        local period = ghost_loop_period(line)
        if ts.ghost_cp_crossings and period > 0 then
          local mult       = speed_mult_from_time(tstate.best_time)
          local spawn_pops = id == State.active_track
          for i = 1, count do
            local offset = (i - 1) / count * period
            local phase  = (sim_time + offset) % period
            local prev   = ts.ghost_prev_phase[i]
            if prev then
              bank_ghost_events(ts.ghost_cp_crossings, GHOST_CHECKPOINT_PAY * mult, "cash", prev, phase, spawn_pops)
              if ts.ghost_coin_pickups then
                bank_ghost_events(ts.ghost_coin_pickups, GHOST_COIN_PAY * mult, "coin", prev, phase, spawn_pops)
              end
            end
            ts.ghost_prev_phase[i] = phase
          end
        end
      end
    end
  end
end

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

    local id       = State.active_track
    local tdata    = TRACKS[id]
    local car_rect = { x = car.x, y = car.y, w = CAR_SIZE, h = CAR_SIZE }

    for ci = 1, active_coin_count() do
      local coin = tdata.coins[ci]
      if not race.coins_collected[ci] and util.rect_overlap(car_rect, coin_rect(coin)) then
        race.coins_collected[ci] = true
        State.coins              = State.coins + COIN_PAY
        race.coins_earned        = race.coins_earned + COIN_PAY
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

    local cp = tdata.checkpoints[race.next_checkpoint]
    if cp and util.rect_overlap(car_rect, checkpoint_rect(cp)) then
      State.money               = State.money + CHECKPOINT_PAY
      race.earned               = race.earned + CHECKPOINT_PAY
      cash_pops[#cash_pops + 1] = {
        amount = CHECKPOINT_PAY,
        currency = "cash",
        x = car.x + CAR_SIZE / 2,
        y = car.y,
        age = 0,
      }
      race.next_checkpoint      = race.next_checkpoint + 1
      if race.next_checkpoint > #tdata.checkpoints then
        finish_race()
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
  local m     = TRACKS[State.active_track].map
  local layer = m.layers[1].data
  local mw    = m.width
  local mh    = m.height
  for row = 0, mh - 1 do
    for col = 0, mw - 1 do
      local tile = layer[row * mw + col + 1]
      gfx.rect_fill(col * tile_size, row * tile_size, tile_size, tile_size,
        tile_colors[tile] or gfx.COLOR_INDIGO)
    end
  end
end

local function draw_coins(collected)
  local bob   = math.sin(usagi.elapsed * COIN_BOB_HZ * 2 * math.pi) * COIN_BOB_AMP
  local tdata = TRACKS[State.active_track]
  for ci = 1, active_coin_count() do
    if not (collected and collected[ci]) then
      local coin = tdata.coins[ci]
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

-- Flickering exhaust flames out the back of the car during a BTN3 boost.
-- Driven by car.boost_flame_t so a boost flames for the full burst window even
-- when fired below top speed. Drawn before draw_car so the car sits on top.
local function draw_flames()
  if car.boost_flame_t <= 0 then return end
  local cx     = car.x + 8
  local cy     = car.y + 8
  local back   = car.facing_angle + math.pi
  -- Flicker the flame length each frame for a lively exhaust.
  local flick  = 0.6 + 0.4 * math.abs(math.sin(usagi.elapsed * 40))
  local layers = {
    { len = 11 * flick, half = 4, color = gfx.COLOR_RED },
    { len = 8 * flick,  half = 3, color = gfx.COLOR_ORANGE },
    { len = 5 * flick,  half = 2, color = gfx.COLOR_YELLOW },
  }
  local perp   = car.facing_angle + math.pi / 2
  for _, fl in ipairs(layers) do
    local tip  = util.vec_from_angle(back, 4 + fl.len)
    local base = util.vec_from_angle(back, 4)
    local off  = util.vec_from_angle(perp, fl.half)
    gfx.tri_fill(
      cx + tip.x, cy + tip.y,
      cx + base.x - off.x, cy + base.y - off.y,
      cx + base.x + off.x, cy + base.y + off.y,
      fl.color)
  end
end

local function draw_car()
  local car_tint = gfx.COLOR_WHITE
  if car.boost_ready then
    car_tint = util.flash(usagi.elapsed, 8) and gfx.COLOR_WHITE or gfx.COLOR_GREEN
  end
  gfx.spr_ex(2, car.x, car.y, false, false, car.facing_angle - math.pi / 2, car_tint, 1)
end

local function draw_hud_currencies()
  local scale          = 2
  local _, th          = usagi.measure_text("0")
  local bal_y          = 6
  local rate_y         = bal_y + th * scale + 3
  local gap            = 24

  local money_text     = string.format("$%.0f", State.money)
  local cash_rate_text = string.format("%.2f $/sec", ghost_cash_rate())
  local cash_w         = math.max(usagi.measure_text(money_text) * scale,
    usagi.measure_text(cash_rate_text))

  local coin_text      = string.format(COIN_ICON .. "%.0f", State.coins)
  local coin_rate_text = string.format("%.2f " .. COIN_ICON .. "/sec", ghost_coin_rate())
  local coin_w         = math.max(usagi.measure_text(coin_text) * scale,
    usagi.measure_text(coin_rate_text))

  local cash_x         = (game_width - (cash_w + gap + coin_w)) / 2
  local coin_x         = cash_x + cash_w + gap

  gfx.text_ex(money_text, cash_x, bal_y, scale, 0, gfx.COLOR_GREEN, 1)
  gfx.text_ex(cash_rate_text, cash_x, rate_y, 1, 0, gfx.COLOR_GREEN, 1)
  gfx.text_ex(coin_text, coin_x, bal_y, scale, 0, gfx.COLOR_YELLOW, 1)
  gfx.text_ex(coin_rate_text, coin_x, rate_y, 1, 0, gfx.COLOR_YELLOW, 1)
end

local function draw_cash_pops()
  for _, p in ipairs(cash_pops) do
    local t     = p.age / CASH_POP_LIFE
    local scale = p.ghost and 1 or 2
    local alpha = (1 - t) * (p.ghost and 0.6 or 1) * (p.alpha_mul or 1)
    local py    = p.y - t * CASH_POP_RISE
    local color = gfx.COLOR_GREEN
    if p.currency == "coin" then color = gfx.COLOR_YELLOW end
    local text = string.format("%.0f", p.amount)
    local tw   = usagi.measure_text(text) * scale
    local px   = math.floor(p.x - tw / 2)
    gfx.text_ex(text, px, py, scale, 0, color, alpha)
  end
end

local function draw_countdown()
  dim.draw(game_width, game_height)
  local text   = tostring(math.ceil(countdown_time))
  local scale  = 12
  local tw, th = usagi.measure_text(text)
  local x      = math.floor((game_width - tw * scale) / 2)
  local y      = math.floor((game_height - th * scale) / 2)
  gfx.text_ex(text, x, y, scale, 0, gfx.COLOR_WHITE, 1)
end

local function draw_sim_ghosts(alpha)
  local id     = State.active_track
  local tstate = State.tracks[id]
  if not tstate then return end
  local count = tstate.ghosts
  local line  = tstate.ghost_line
  if count <= 0 or not line then return end
  local period = ghost_loop_period(line)
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

local SHOP_COST_W = 50

local function shop_button(item, x, y, w)
  local kind     = item.kind
  local label    = item.label
  local cost     = upgrade_cost(kind)
  local currency = item.currency

  local cost_text, cost_color
  if cost == nil then
    cost_text = "MAX"
  elseif cost == 0 then
    cost_text = "FREE"
  elseif currency == "coin" then
    cost_text  = COIN_ICON .. tostring(cost)
    cost_color = gfx.COLOR_WHITE
  else
    cost_text  = "$" .. tostring(cost)
    cost_color = gfx.COLOR_WHITE
  end

  local balance    = currency == "coin" and State.coins or State.money
  local affordable = cost ~= nil and (cost == 0 or balance >= cost)
  if kind == "ghosts" and not State.tracks[State.active_track].ghost_line then
    affordable = false
  end

  local _, th = usagi.measure_text(label)
  local bh    = th * 2 + 4

  ui.label(label, x, y + math.floor((bh - th * 2) / 2))

  local bx      = x + w - SHOP_COST_W
  local clicked = ui.button(cost_text, bx, y,
    { w = SHOP_COST_W, disabled = not affordable, text = cost_color })
  return clicked, bh
end

local function try_buy(kind)
  local id   = State.active_track
  local cost = upgrade_cost(kind)
  if cost == nil then return end
  if kind == "ghosts" and not State.tracks[id].ghost_line then return end
  local currency = track_shop_item(id, kind).currency
  local balance  = currency == "coin" and State.coins or State.money
  if cost > 0 and balance < cost then return end
  if currency == "coin" then
    State.coins = State.coins - cost
  else
    State.money = State.money - cost
  end
  if kind == "ghosts" or kind == "coins" then
    State.tracks[id][kind] = State.tracks[id][kind] + 1
    if kind == "ghosts" then get_track_sim(id).ghost_prev_phase = {} end
    if kind == "coins" then rebuild_ghost_sim(id) end
  else
    State[kind] = State[kind] + 1
  end
  apply_car_upgrades()
  save_game()
end

local function next_locked_track()
  for _, id in ipairs(TRACK_ORDER) do
    if not State.unlocked[id] then return id end
  end
  return nil
end

local function try_unlock_track(id)
  local cost = TRACKS[id].unlock_cost
  if not cost or State.money < cost then return end
  State.money        = State.money - cost
  State.unlocked[id] = true
  if not State.tracks[id] then
    State.tracks[id] = default_track_state(id)
  end
  rebuild_ghost_sim(id)
  save_game()
end

local function draw_buy_shop()
  local x       = 8
  local w       = 200
  local gap     = 6

  -- Track navigation
  local id      = State.active_track
  local idx     = get_track_index(id)
  local tdata   = TRACKS[id]
  local tstate  = State.tracks[id]
  local _, th_a = usagi.measure_text("A")
  local nav_y   = 50
  local arrow_w = 18

  if idx > 1 then
    if ui.button("<", x, nav_y, { w = arrow_w }) then
      State.active_track = TRACK_ORDER[idx - 1]
    end
  end
  if idx < #TRACK_ORDER and State.unlocked[TRACK_ORDER[idx + 1]] then
    if ui.button(">", x + w - arrow_w, nav_y, { w = arrow_w }) then
      State.active_track = TRACK_ORDER[idx + 1]
    end
  end

  local lbl_text = tdata.label
  local lbl_w    = usagi.measure_text(lbl_text) * 2
  gfx.text_ex(lbl_text, x + math.floor((w - lbl_w) / 2), nav_y + 2, 2, 0, gfx.COLOR_WHITE, 1)

  -- Speed mult + per-track rates under the nav label
  local info_y    = nav_y + th_a * 2 + 6
  local rate_text = string.format("%.2f $/sec", track_cash_rate(id))
  local coin_text = string.format("%.2f " .. COIN_ICON .. "/sec", track_coin_rate(id))
  local rate_w    = usagi.measure_text(rate_text)
  local coin_w    = usagi.measure_text(coin_text)
  local info_gap  = 8
  local info_x    = x + math.floor((w - (rate_w + info_gap + coin_w)) / 2)
  gfx.text_ex(rate_text, info_x, info_y, 1, 0, gfx.COLOR_GREEN, 1)
  gfx.text_ex(coin_text, info_x + rate_w + info_gap, info_y, 1, 0, gfx.COLOR_YELLOW, 1)

  -- Shop items
  local shop_y = info_y + th_a + 6

  -- Shop items are declared per-track in TRACKS[id].shop. accel/top_speed still
  -- upgrade the global car; only their purchase location is track-specific.
  for _, item in ipairs(tdata.shop) do
    local clicked, bh = shop_button(item, x, shop_y, w)
    if clicked then try_buy(item.kind) end
    shop_y = shop_y + bh + gap
  end

  local race_x = math.floor((game_width - w) / 2)
  if ui.button("RACE", race_x, game_height - 80, { w = w, scale = 3 }) then
    start_race()
  end

  local next_track = next_locked_track()
  if next_track then
    local ntdata   = TRACKS[next_track]
    local cost     = ntdata.unlock_cost
    local can_buy  = State.money >= cost
    local btn_text = string.format("Buy %s - $%d", ntdata.label, cost)
    if ui.button(btn_text, math.floor((game_width - w) / 2), game_height - 42,
          { w = w, disabled = not can_buy }) then
      try_unlock_track(next_track)
    end
  end
end

local CHECKPOINT_LABEL_SCALE = 2

local function draw_checkpoint(cp, n, faded)
  local rect          = checkpoint_rect(cp)
  local outline_color = gfx.COLOR_DARK_GREEN
  if not faded then
    outline_color = gfx.COLOR_DARK_GRAY
    gfx.rect_fill(rect.x, rect.y, rect.w, rect.h, gfx.COLOR_DARK_GREEN)
  end
  gfx.rect(rect.x, rect.y, rect.w, rect.h, outline_color)

  local label = tostring(n)
  local tw, th = usagi.measure_text(label)
  local tx = math.floor(rect.x + (rect.w - tw * CHECKPOINT_LABEL_SCALE) / 2)
  local ty = math.floor(rect.y + (rect.h - th * CHECKPOINT_LABEL_SCALE) / 2)
  gfx.text_ex(label, tx, ty, CHECKPOINT_LABEL_SCALE, 0, gfx.COLOR_BLACK, faded and GHOST_ALPHA or 1)
end

local function draw_buy()
  draw_track()
  dim.draw(game_width, game_height)
  local checkpoints = TRACKS[State.active_track].checkpoints
  for i, cp in ipairs(checkpoints) do
    draw_checkpoint(cp, i, true)
  end
  draw_coins()
  draw_sim_ghosts(GHOST_ALPHA)
  draw_cash_pops()
  draw_hud_currencies()
  draw_buy_shop()
end

-- Race mode -----------------------------------------------------------------

local function draw_race_ghost()
  local id     = State.active_track
  local tstate = State.tracks[id]
  if tstate.ghosts <= 0 then return end
  local g = sample_line_at(tstate.ghost_line, State.race.time)
  if g then
    gfx.spr_ex(2, g.x, g.y, false, false, g.angle - math.pi / 2, gfx.COLOR_WHITE, GHOST_ALPHA)
  end
end

local function draw_checkpoints()
  local active      = State.race.next_checkpoint
  local checkpoints = TRACKS[State.active_track].checkpoints
  for i = active, #checkpoints do
    draw_checkpoint(checkpoints[i], i, i ~= active)
  end
end

local function draw_race_result()
  dim.draw(game_width, game_height)
  local race = State.race

  local function centered_text(text, y, scale, color)
    local tw = usagi.measure_text(text) * scale
    local cx = math.floor((game_width - tw) / 2)
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
    local cx = math.floor((game_width - (vw + uw)) / 2)
    gfx.text_ex(value_text, cx, y, scale, 0, value_color, 1)
    gfx.text_ex(unit_text, cx + vw, y, scale, 0, unit_color, 1)
  end

  local y = 80

  if race.has_baseline then
    local time_col = delta_color(race.time_delta)
    local sign = race.time_delta >= 0 and "-" or "+"
    centered_text(string.format("%s%.2fs", sign, math.abs(race.time_delta)), y, 2, time_col)
    y               = y + 22

    local cash_col  = delta_color(race.cash_rate_delta)
    local cash_sign = race.cash_rate_delta >= 0 and "+" or ""
    centered_rate_delta(string.format("%s%.2f", cash_sign, race.cash_rate_delta),
      " $/sec", cash_col, gfx.COLOR_DARK_GREEN, y, 2)
    y               = y + 22

    local coin_col  = delta_color(race.coin_rate_delta)
    local coin_sign = race.coin_rate_delta >= 0 and "+" or ""
    centered_rate_delta(string.format("%s%.2f", coin_sign, race.coin_rate_delta),
      " " .. COIN_ICON .. "/sec", coin_col, gfx.COLOR_YELLOW, y, 2)
    y          = y + 34

    local bw   = 150
    local btnm = 8
    local lx   = math.floor((game_width - bw * 2 - btnm) / 2)
    if ui.button("USE THIS RUN", lx, y, { w = bw, scale = 2 }) then
      promote_run()
      return_to_buy()
    end
    if ui.button("KEEP CURRENT", lx + bw + btnm, y, { w = bw, scale = 2 }) then
      return_to_buy()
    end
  else
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
  if race.phase ~= "result" then draw_checkpoints() end
  draw_coins(race.coins_collected)
  draw_skid_marks()
  draw_sim_ghosts(GHOST_RACE_ALPHA)
  draw_race_ghost()
  draw_flames()
  draw_car()
  draw_cash_pops()
  draw_hud_currencies()

  if race.phase == "countdown" then
    draw_countdown()
  elseif race.phase == "result" then
    draw_race_result()
  else
    if ui.button("QUIT", 5, 5, { w = 50 }) then
      return_to_buy()
    end
  end
end

function _draw()
  if State.mode == "race" then
    draw_race()
  else
    draw_buy()
  end
end
