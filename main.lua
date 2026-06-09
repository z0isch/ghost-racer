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

local RUN_DURATION = 10
local GHOST_ALPHA = 0.4

local run = {
  active = false,
  time = 0,
  samples = {}
}

local ghost = nil
local ghost_time = 0

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

---Interpolate the ghost's recorded transform at a given time into its run
---@param time number
---@return table|nil
local function ghost_sample_at(time)
  if not ghost or #ghost == 0 then return nil end

  if time <= ghost[1].t then return ghost[1] end
  local last = ghost[#ghost]
  if time >= last.t then return last end

  for i = 1, #ghost - 1 do
    local a = ghost[i]
    local b = ghost[i + 1]
    if time >= a.t and time <= b.t then
      local span = b.t - a.t
      local t = 0
      if span > 0 then t = (time - a.t) / span end
      return {
        x = util.lerp(a.x, b.x, t),
        y = util.lerp(a.y, b.y, t),
        angle = lerp_angle(a.angle, b.angle, t),
        drift = a.drift
      }
    end
  end

  return last
end

---Stop the current run, promoting its recording to the new ghost
local function end_run()
  if run.active and #run.samples > 0 then
    ghost = run.samples
    ghost_time = 0
  end
  run.active = false
end

---Reset the car to spawn and begin a fresh run
local function reset_run()
  end_run()

  car.x = 10
  car.y = 100
  car.vel = 0
  car.facing_angle = 0
  car.vel_angle = 0
  car.is_drifitng = false

  skid_marks = {}
  skid_prev = nil

  run.active = true
  run.time = 0
  run.samples = {}
end

function _update(dt)
  if input.pressed(input.BTN3) then
    reset_run()
  end

  if not run.active then return end

  if ghost then
    ghost_time = ghost_time + dt
  end

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

  run.time = run.time + dt
  run.samples[#run.samples + 1] = {
    t = run.time,
    x = car.x,
    y = car.y,
    angle = car.facing_angle,
    drift = car.is_drifitng
  }

  if run.time >= RUN_DURATION then
    end_run()
  end
end

function _draw(dt)
  gfx.clear(gfx.COLOR_INDIGO)
  for _, mark in ipairs(skid_marks) do
    gfx.line(mark.lx1, mark.ly1, mark.lx2, mark.ly2, gfx.COLOR_BLACK)
    gfx.line(mark.rx1, mark.ry1, mark.rx2, mark.ry2, gfx.COLOR_BLACK)
  end

  if run.active and ghost then
    local g = ghost_sample_at(ghost_time)
    if g then
      gfx.spr_ex(2, g.x, g.y, false, false, g.angle - math.pi / 2, gfx.COLOR_WHITE, GHOST_ALPHA)
    end
  end

  gfx.spr_ex(2, car.x, car.y, false, false, car.facing_angle - math.pi / 2, gfx.COLOR_WHITE, 1)
end
