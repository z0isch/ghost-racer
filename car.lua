local road       = require "road"
local angle      = require "angle"
local track_data = require "track_data"

local CAR_SIZE         = 16
local CAR_MARGIN       = 3
local ACCEL_BASE       = 50
local ACCEL_STEP       = 15
local TOP_VEL_BASE     = 200
local TOP_VEL_STEP     = 30
local MAX_BOOSTS       = 10
local OVERSPEED_IMPULSE = 100
local OVERSPEED_DECAY  = 100
local BOOST_FLAME_TIME = 0.8

local M = {}

M.SIZE   = CAR_SIZE
M.MARGIN = CAR_MARGIN

local skid_marks = {}
local skid_prev  = nil

local car = {
  x                  = 0,
  y                  = 0,
  vel                = 0,
  top_vel            = TOP_VEL_BASE,
  facing_angle       = 0,
  vel_angle          = 0,
  turn_speed         = 0.03,
  drift_turn_speed   = 0.06,
  drift_slide        = math.pi / 8,
  drift_deccel       = 100,
  accel              = ACCEL_BASE,
  deccel             = 150,
  is_drifitng        = false,
  turn_speed_factor  = 0.0001,
  skid_max_age       = 2.5,
  skid_max_count     = 200,
  boost_value        = 120,
  boost_length       = 1.2,
  drift_threshold    = 0.6,
  drift_time         = 0,
  boost_ready        = false,
  boost_time_remaining = 0,
  boosts             = MAX_BOOSTS,
  boost_flame_t      = 0,
}

function M.reset()
  local spawn          = track_data.TRACKS[State.active_track].spawn
  local ts             = track_data.tile_size
  car.x                    = spawn.col * ts
  car.y                    = spawn.row * ts
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
end

function M.apply_upgrades()
  car.accel   = ACCEL_BASE + State.accel * ACCEL_STEP
  car.top_vel = TOP_VEL_BASE + State.top_speed * TOP_VEL_STEP
end

function M.pose()
  return { x = car.x, y = car.y, angle = car.facing_angle, drift = car.is_drifitng }
end

function M.rect()
  return { x = car.x, y = car.y, w = CAR_SIZE, h = CAR_SIZE }
end

function M.update(dt)
  local holding_left  = input.held(input.LEFT)
  local holding_right = input.held(input.RIGHT)
  local is_drifitng   = false
  if input.held(input.BTN2) then is_drifitng = true end

  local target_vel_angle = car.facing_angle
  if is_drifitng and (holding_left or holding_right) then
    local dir = holding_left and -1 or 1
    target_vel_angle = car.facing_angle + (dir * 0.005 * car.vel)
  end

  if is_drifitng then
    car.vel_angle = angle.lerp(car.vel_angle, target_vel_angle, car.drift_slide * dt)
  else
    car.vel_angle = car.facing_angle
  end

  local drift_factor = is_drifitng and 1.1 or 1
  local vel_vec      = util.vec_from_angle(car.vel_angle, drift_factor * car.vel * dt)
  local new_x        = util.clamp(car.x + vel_vec.x, 0, usagi.GAME_W - CAR_SIZE)
  local new_y        = util.clamp(car.y + vel_vec.y, 0, usagi.GAME_H - CAR_SIZE)

  if road.on_road(new_x, new_y, CAR_SIZE, CAR_MARGIN) then
    car.x = new_x
    car.y = new_y
  elseif road.on_road(new_x, car.y, CAR_SIZE, CAR_MARGIN) then
    car.x = new_x
    car.vel = car.vel * 0.5
  elseif road.on_road(car.x, new_y, CAR_SIZE, CAR_MARGIN) then
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
    car.vel = math.max(effective_top_vel, car.vel - OVERSPEED_DECAY * dt)
  elseif input.held(input.BTN1) then
    car.vel = util.clamp(car.vel + car.accel * dt, 0, effective_top_vel)
  else
    car.vel = util.clamp(car.vel - car.deccel * dt, 0, effective_top_vel)
  end

  if is_drifitng then
    car.vel = math.max(0, car.vel - car.drift_deccel * dt)
  end

  if car.boost_flame_t > 0 then
    car.boost_flame_t = math.max(0, car.boost_flame_t - dt)
  end

  if holding_left or holding_right then
    local turn_speed = is_drifitng and car.drift_turn_speed or car.turn_speed
    local dir        = holding_left and -1 or 1
    car.facing_angle = angle.normalize(
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
        lx1 = skid_prev.lx, ly1 = skid_prev.ly,
        lx2 = lx,           ly2 = ly,
        rx1 = skid_prev.rx, ry1 = skid_prev.ry,
        rx2 = rx,           ry2 = ry,
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
end

function M.draw()
  local car_tint = gfx.COLOR_WHITE
  if car.boost_ready then
    car_tint = util.flash(usagi.elapsed, 8) and gfx.COLOR_WHITE or gfx.COLOR_GREEN
  end
  gfx.spr_ex(2, car.x, car.y, false, false, car.facing_angle - math.pi / 2, car_tint, 1)
end

function M.draw_flames()
  if car.boost_flame_t <= 0 then return end
  local cx     = car.x + 8
  local cy     = car.y + 8
  local back   = car.facing_angle + math.pi
  local flick  = 0.6 + 0.4 * math.abs(math.sin(usagi.elapsed * 40))
  local layers = {
    { len = 11 * flick, half = 4, color = gfx.COLOR_RED },
    { len = 8  * flick, half = 3, color = gfx.COLOR_ORANGE },
    { len = 5  * flick, half = 2, color = gfx.COLOR_YELLOW },
  }
  local perp = car.facing_angle + math.pi / 2
  for _, fl in ipairs(layers) do
    local tip  = util.vec_from_angle(back, 4 + fl.len)
    local base = util.vec_from_angle(back, 4)
    local off  = util.vec_from_angle(perp, fl.half)
    gfx.tri_fill(
      cx + tip.x,          cy + tip.y,
      cx + base.x - off.x, cy + base.y - off.y,
      cx + base.x + off.x, cy + base.y + off.y,
      fl.color)
  end
end

function M.draw_skid_marks()
  for _, mark in ipairs(skid_marks) do
    gfx.line(mark.lx1, mark.ly1, mark.lx2, mark.ly2, gfx.COLOR_BLACK)
    gfx.line(mark.rx1, mark.ry1, mark.rx2, mark.ry2, gfx.COLOR_BLACK)
  end
end

return M
