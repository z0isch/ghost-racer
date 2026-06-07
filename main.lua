local game_width = 640
local game_height = 360

function _config()
  return { name = "Usagi Test", game_width = game_width, game_height = game_height }
end

function _init()
  State = {}
end

local skid_marks = {}
local skid_prev = nil

local car = {
  x = 10,
  y = 100,
  vel = 0,
  top_vel = 200,
  facing_angle = 0,
  vel_angle = 0,
  turn_speed = 0.03,
  drift_turn_speed = 0.06,
  drift_slide = math.pi / 8,
  accel = 50,
  deccel = 150,
  is_drifitng = false,
  turn_speed_factor = 0.0001,
  skid_max_age = 2.5,
  skid_max_count = 200
}

---Normalize an angle to be between 0 and 2 * PI
---@param angle number
---@return number
local function nomalize_angle(angle)
  return angle - 2 * math.pi * math.floor(angle / (2 * math.pi))
end

---Lerp between two angles, taking the shortest arc
---@param a number
---@param b number
---@param t number
---@return number
local function lerp_angle(a, b, t)
  local diff = b - a
  diff = diff - 2 * math.pi * math.floor((diff + math.pi) / (2 * math.pi))
  return a + diff * math.min(t, 1)
end

function _update(dt)
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
  car.x = util.clamp(car.x + vel_vec.x, 0, game_width - 14)
  car.y = util.clamp(car.y + vel_vec.y, 0, game_height - 14)

  if input.held(input.BTN1)
  then
    car.vel = util.clamp(car.vel + car.accel * dt, 0, car.top_vel)
  else
    car.vel = util.clamp(car.vel - car.deccel * dt, 0, car.top_vel)
  end

  if car.vel > 0 and (holding_left or holding_right)
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
  else
    if car.is_drifitng then
      effect.screen_shake(.2, 1.5)
    end
    car.is_drifitng = false
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
end

function _draw(dt)
  gfx.clear(gfx.COLOR_DARK_BLUE)
  for _, mark in ipairs(skid_marks) do
    gfx.line(mark.lx1, mark.ly1, mark.lx2, mark.ly2, gfx.COLOR_BLACK)
    gfx.line(mark.rx1, mark.ry1, mark.rx2, mark.ry2, gfx.COLOR_BLACK)
  end
  gfx.spr_ex(2, car.x, car.y, false, false, car.facing_angle - math.pi / 2, gfx.COLOR_WHITE, 1)
end
