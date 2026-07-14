local road               = require "road"
local angle              = require "angle"
local track_data         = require "track_data"

local CAR_SIZE           = 16
local CAR_MARGIN         = 3
local ACCEL_BASE         = 30
local ACCEL_STEP         = 10
local TOP_VEL_BASE       = 200
local TOP_VEL_STEP       = 15
local OVERSPEED_IMPULSE  = 100
local OVERSPEED_DECAY    = 100
local WALL_DECEL         = 500
-- Movement is swept in substeps of at most this many pixels so a fast car
-- (boost stacking, dt spike) can't jump its collision samples over a wall
-- tile in a single frame.
local MAX_MOVE_STEP      = 4
local SQUEEL_MIN_VEL     = 80
-- The engine loop plays on the music channel: unlike sfx voices,
-- music.mutate can retune volume and pitch every frame without restarting
-- the sample.
local ENGINE_MIN_VOL     = 0.3
local ENGINE_MIN_PITCH   = 0.8
local ENGINE_MAX_PITCH   = 1.4
local BOOST_FLAME_TIME   = 0.8
local BOOST_ORBIT_RADIUS = 12
local BOOST_ORBIT_SPEED  = 3
-- Rotating to within this angle of a full 180 mid-drift flips the drift
-- boost into the opposite gear.
local DRIFT_FLIP_GRACE   = math.pi / 6

local M                  = {}

M.SIZE                   = CAR_SIZE
M.MARGIN                 = CAR_MARGIN

-- This module is stateless: every function takes the car state table as its
-- first argument. Callers own the table and keep it somewhere reload-safe
-- (the game stores it on State.car) so a mid-race dev live-reload doesn't
-- snap the car back to spawn.
local function default_car()
  return {
    x                    = 0,
    y                    = 0,
    vel                  = 0,
    top_vel              = TOP_VEL_BASE,
    facing_angle         = 0,
    vel_angle            = 0,
    turn_rate_slow       = 2.0,
    turn_rate_fast       = 1.0,
    turn_ref_speed       = TOP_VEL_BASE,
    drift_turn_rate      = 3.6,
    drift_slide          = math.pi / 8,
    drift_deccel         = 200,
    accel                = ACCEL_BASE,
    deccel               = 150,
    is_drifitng          = false,
    skid_max_age         = 2.5,
    skid_max_count       = 200,
    skid_marks           = {},
    skid_prev            = nil,
    boost_value          = 200,
    boost_length         = 1.2,
    drift_threshold      = 0.5,
    drift_time           = 0,
    boost_ready          = false,
    boost_time_remaining = 0,
    drift_enabled        = false,
    drift_boost_enabled  = false,
    reverse_enabled      = false,
    drift_dir            = 0,
    drift_start_angle    = 0,
    drift_flipped        = false,
    max_boosts           = 0,
    boosts               = 0,
    boost_flame_t        = 0,
    engine_on            = false,
  }
end

M.default_state = default_car

function M.reset(car, spawn)
  local ts                 = track_data.tile_size
  car.x                    = spawn.col * ts
  car.y                    = spawn.row * ts
  car.vel                  = 0
  car.facing_angle         = 0
  car.vel_angle            = 0
  car.is_drifitng          = false
  car.drift_time           = 0
  car.drift_dir            = 0
  car.drift_start_angle    = 0
  car.drift_flipped        = false
  car.boost_ready          = false
  car.boost_time_remaining = 0
  car.boosts               = car.max_boosts
  car.boost_flame_t        = 0
  car.skid_marks           = {}
  car.skid_prev            = nil
end

-- The engine doesn't expose music.is_playing, so callers that stop the
-- engine loop outside of M.update (scene exits, race finish) must go through
-- here to keep car.engine_on in sync.
function M.stop_engine(car)
  music.stop()
  car.engine_on = false
end

function M.apply_upgrades(car, accel_lvl, top_speed_lvl, drift_enabled, drift_boost_enabled, boost_ranks, reverse_enabled)
  car.accel               = ACCEL_BASE + accel_lvl * ACCEL_STEP
  car.top_vel             = TOP_VEL_BASE + top_speed_lvl * TOP_VEL_STEP
  car.drift_enabled       = drift_enabled or false
  car.drift_boost_enabled = drift_boost_enabled or false
  car.max_boosts          = boost_ranks or 0
  car.reverse_enabled     = reverse_enabled or false
end

function M.pose(car)
  return { x = car.x, y = car.y, angle = car.facing_angle, drift = car.is_drifitng }
end

function M.rect(car)
  return { x = car.x, y = car.y, w = CAR_SIZE, h = CAR_SIZE }
end

function M.update(car, dt, map)
  local holding_left  = input.held(input.LEFT)
  local holding_right = input.held(input.RIGHT)
  local is_drifitng   = false
  if car.drift_enabled and input.held(input.BTN2) then is_drifitng = true end
  -- A drift locks in the direction of travel it started with; vel may bleed
  -- to 0 during the drift but never crosses to the other sign.
  if is_drifitng and not car.is_drifitng then
    car.drift_dir         = car.vel < 0 and -1 or 1
    car.drift_start_angle = car.facing_angle
  end

  local target_vel_angle = car.facing_angle
  if is_drifitng and (holding_left or holding_right) then
    local dir = holding_left and -1 or 1
    target_vel_angle = car.facing_angle + (dir * 0.005 * math.abs(car.vel))
  end

  if is_drifitng then
    car.vel_angle = angle.lerp(car.vel_angle, target_vel_angle, car.drift_slide * dt)
  else
    car.vel_angle = car.facing_angle
  end

  local drift_factor = is_drifitng and 1.1 or 1
  local vel_vec      = util.vec_from_angle(car.vel_angle, drift_factor * car.vel * dt)

  local function wall_decel(vel)
    if vel < 0 then return math.min(0, vel + WALL_DECEL * dt) end
    return math.max(0, vel - WALL_DECEL * dt)
  end

  local max_axis = math.max(math.abs(vel_vec.x), math.abs(vel_vec.y))
  local steps    = math.max(1, math.ceil(max_axis / MAX_MOVE_STEP))
  local step_x   = vel_vec.x / steps
  local step_y   = vel_vec.y / steps
  local hit_wall = false
  for _ = 1, steps do
    local new_x = util.clamp(car.x + step_x, 0, usagi.GAME_W - CAR_SIZE)
    local new_y = util.clamp(car.y + step_y, 0, usagi.GAME_H - CAR_SIZE)
    if road.on_road(map, new_x, new_y, CAR_SIZE, CAR_MARGIN) then
      car.x = new_x
      car.y = new_y
    elseif road.on_road(map, new_x, car.y, CAR_SIZE, CAR_MARGIN) then
      car.x = new_x
      hit_wall = true
    elseif road.on_road(map, car.x, new_y, CAR_SIZE, CAR_MARGIN) then
      car.y = new_y
      hit_wall = true
    else
      hit_wall = true
      break
    end
  end
  if hit_wall then car.vel = wall_decel(car.vel) end

  local effective_top_vel = car.top_vel
  local min_vel           = car.reverse_enabled and -effective_top_vel or 0

  if input.pressed(input.BTN3) and car.boosts > 0 then
    local boost_dir = car.vel < 0 and -1 or 1
    if is_drifitng then boost_dir = car.drift_dir end
    car.vel = car.vel + boost_dir * OVERSPEED_IMPULSE
    car.boosts = car.boosts - 1
    car.boost_flame_t = BOOST_FLAME_TIME
    sfx.play("boost")
  end

  -- deccel is the braking rate (fighting the current direction of travel),
  -- accel builds speed in the direction already headed -- symmetric for
  -- forward and reverse.
  if car.vel > effective_top_vel then
    car.vel = math.max(effective_top_vel, car.vel - OVERSPEED_DECAY * dt)
  elseif car.vel < min_vel then
    car.vel = math.min(min_vel, car.vel + OVERSPEED_DECAY * dt)
  elseif input.held(input.BTN1) then
    local rate = car.vel < 0 and car.deccel or car.accel
    car.vel = util.clamp(car.vel + rate * dt, min_vel, effective_top_vel)
  else
    local rate = car.vel > 0 and car.deccel or car.accel
    car.vel = util.clamp(car.vel - rate * dt, min_vel, effective_top_vel)
  end

  if is_drifitng then
    if car.vel > 0 then
      car.vel = math.max(0, car.vel - car.drift_deccel * dt)
    else
      car.vel = math.min(0, car.vel + car.drift_deccel * dt)
    end
    if car.drift_dir < 0 then
      car.vel = math.min(0, car.vel)
    else
      car.vel = math.max(0, car.vel)
    end
  end

  if car.boost_flame_t > 0 then
    car.boost_flame_t = math.max(0, car.boost_flame_t - dt)
  end

  if holding_left or holding_right then
    local dir = holding_left and -1 or 1
    local rate
    if is_drifitng then
      rate = car.drift_turn_rate
    else
      local t = util.clamp(math.abs(car.vel) / car.turn_ref_speed, 0, 1)
      rate = car.turn_rate_slow + (car.turn_rate_fast - car.turn_rate_slow) * t
    end
    car.facing_angle = angle.normalize(car.facing_angle + dir * rate * dt)
  end

  if is_drifitng then
    car.is_drifitng   = true
    car.drift_time    = car.drift_time + dt
    local turned      = angle.normalize(car.facing_angle - car.drift_start_angle)
    car.drift_flipped = car.reverse_enabled and math.abs(turned - math.pi) < DRIFT_FLIP_GRACE
    if car.drift_time >= car.drift_threshold and not car.boost_ready and car.drift_boost_enabled then
      car.boost_ready = true
    end
  else
    if car.boost_ready then
      car.boost_time_remaining = car.boost_length
      local boost_dir = car.drift_dir
      if car.drift_flipped then
        -- The 180 carries the built-up speed into the opposite gear.
        boost_dir = -car.drift_dir
        car.vel   = -car.vel
      end
      if boost_dir < 0 then
        car.vel = math.max(car.vel - car.boost_value, -car.top_vel)
      else
        car.vel = math.min(car.vel + car.boost_value, car.top_vel)
      end
      car.boost_ready = false
      sfx.play("boost")
    end
    car.is_drifitng   = false
    car.drift_time    = 0
    car.drift_flipped = false
  end

  if is_drifitng and car.vel ~= 0 then
    if not sfx.is_playing("squeal") and math.abs(car.vel) > SQUEEL_MIN_VEL then
      sfx.play("squeal")
    end
  elseif sfx.is_playing("squeal") then
    sfx.stop("squeal")
  end

  if car.vel ~= 0 then
    local t     = util.clamp(math.abs(car.vel) / car.top_vel, 0, 1)
    local vol   = ENGINE_MIN_VOL + (1 - ENGINE_MIN_VOL) * t
    local pitch = ENGINE_MIN_PITCH + (ENGINE_MAX_PITCH - ENGINE_MIN_PITCH) * t
    if car.engine_on then
      music.mutate(vol, pitch, 0)
    else
      music.play_ex("engine", vol, pitch, 0, true)
      car.engine_on = true
    end
  elseif car.engine_on then
    M.stop_engine(car)
  end

  if car.boost_time_remaining > 0 then
    car.boost_time_remaining = car.boost_time_remaining - dt
  end

  local skid_marks = car.skid_marks
  if is_drifitng then
    local cx   = car.x + 8
    local cy   = car.y + 8
    local back = util.vec_from_angle(car.facing_angle + math.pi, 5)
    local perp = util.vec_from_angle(car.facing_angle + math.pi / 2, 4)
    local lx   = cx + back.x - perp.x
    local ly   = cy + back.y - perp.y
    local rx   = cx + back.x + perp.x
    local ry   = cy + back.y + perp.y
    if car.skid_prev then
      skid_marks[#skid_marks + 1] = {
        lx1 = car.skid_prev.lx,
        ly1 = car.skid_prev.ly,
        lx2 = lx,
        ly2 = ly,
        rx1 = car.skid_prev.rx,
        ry1 = car.skid_prev.ry,
        rx2 = rx,
        ry2 = ry,
        age = 0,
      }
      if #skid_marks > car.skid_max_count then table.remove(skid_marks, 1) end
    end
    car.skid_prev = { lx = lx, ly = ly, rx = rx, ry = ry }
  else
    car.skid_prev = nil
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
end

function M.draw(car)
  local car_tint = gfx.COLOR_WHITE
  if car.boost_ready then
    local ready_color = car.drift_flipped and gfx.COLOR_RED or gfx.COLOR_GREEN
    car_tint = util.flash(usagi.elapsed, 8) and gfx.COLOR_WHITE or ready_color
  end
  gfx.spr_ex(2, car.x, car.y, false, false, car.facing_angle - math.pi / 2, car_tint, 1)
end

function M.draw_flames(car)
  if car.boost_flame_t <= 0 then return end
  local cx     = car.x + 8
  local cy     = car.y + 8
  local back   = car.facing_angle + math.pi
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

function M.draw_boosts(car)
  if car.boosts == 0 then return end
  local cx, cy = car.x + 8, car.y + 8
  local slot   = 2 * math.pi / car.max_boosts
  for b = 1, car.boosts do
    local a = usagi.elapsed * BOOST_ORBIT_SPEED + (b - 1) * slot
    local p = util.vec_from_angle(a, BOOST_ORBIT_RADIUS)
    gfx.circ_fill(cx + p.x, cy + p.y, 3, gfx.COLOR_ORANGE, 1)
  end
end

function M.draw_skid_marks(car)
  for _, mark in ipairs(car.skid_marks) do
    gfx.line(mark.lx1, mark.ly1, mark.lx2, mark.ly2, gfx.COLOR_BLACK)
    gfx.line(mark.rx1, mark.ry1, mark.rx2, mark.ry2, gfx.COLOR_BLACK)
  end
end

return M
