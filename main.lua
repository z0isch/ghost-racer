local game_width = 640
local game_height = 360

function _config()
  return { name = "Usagi Test", game_width, game_height }
end

function _init()
  State = {}
end

local car = {
  x = 10,
  y = 100,
  vel = 0,
  facing_angle = 0,
  turn_speed = 0.03,
  drift_turn_speed = 0.06,
  drift_speed = 1,
  accel = 100,
  deccel = 150,
}

---Normalize an angle to be between 0 and 2 * PI
---@param angle number
---@return number
local function nomalize_angle(angle)
  return angle - 2 * math.pi * math.floor(angle / (2 * math.pi))
end

function _update(dt)
  local holding_left = input.held(input.LEFT)
  local holding_right = input.held(input.RIGHT)

  local facing_angle = car.facing_angle
  if (holding_left or holding_right) and input.held(input.BTN2)
  then
    local dir = 1
    if holding_left then dir = -1 end
    facing_angle = facing_angle + (dir * math.pi)
  end

  local facing_vec = util.vec_from_angle(facing_angle)

  car.x = util.clamp(car.x + facing_vec.x * car.vel * dt, 0, game_width - 14)
  car.y = util.clamp(car.y + facing_vec.y * car.vel * dt, 0, game_height - 14)

  if input.held(input.BTN1)
  then
    car.vel = util.clamp(car.vel + car.accel * dt, 0, 200)
  else
    car.vel = util.clamp(car.vel - car.deccel * dt, 0, 200)
  end

  if (holding_left or holding_right) and car.vel > 0
  then
    local turn_speed = car.turn_speed
    if input.held(input.BTN2) then turn_speed = car.drift_turn_speed end

    local dir = 1
    if holding_left then dir = -1 end

    car.facing_angle = nomalize_angle(car.facing_angle + (dir * turn_speed))
  end
end

function _draw(dt)
  gfx.clear(gfx.COLOR_DARK_BLUE)
  gfx.spr_ex(2, car.x, car.y, false, false, car.facing_angle - math.pi / 2, gfx.COLOR_WHITE, 1)
end
