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
  [0] = gfx.COLOR_PEACH,
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

function _config()
  return { name = "Usagi Test", game_width = game_width, game_height = game_height }
end

function _init()
  State = {}
end

local skid_marks = {}
local skid_prev = nil

local car = {
  x = SPAWN_TILE.col * tile_size,
  y = SPAWN_TILE.row * tile_size,
  vel = 0,
  top_vel = 200,
  facing_angle = 0,
  vel_angle = 0,
  turn_speed = 0.03,
  drift_turn_speed = 0.06,
  drift_slide = math.pi / 8,
  drift_deccel = 180,
  accel = 50,
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

local RUN_DURATION = 100
local GHOST_ALPHA = 0.4

local run = {
  active = true,
  time = 0,
  samples = {}
}

local ghost = nil
local ghost_time = 0
local countdown_time = 0

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

  countdown_time = 3
  run.active = false
  run.time = 0
  run.samples = {}
end

function _update(dt)
  if countdown_time > 0 then
    countdown_time = countdown_time - dt
    if countdown_time <= 0 then
      countdown_time = 0
      run.active = true
    end
    return
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
  for row = 0, map_height - 1 do
    for col = 0, map_width - 1 do
      local tile = map_layer[row * map_width + col + 1]
      gfx.rect_fill(col * tile_size, row * tile_size, tile_size, tile_size, tile_colors[tile] or gfx.COLOR_INDIGO)
    end
  end
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

  local car_tint = gfx.COLOR_WHITE
  if car.boost_ready then
    car_tint = util.flash(usagi.elapsed, 8) and gfx.COLOR_WHITE or gfx.COLOR_GREEN
  end
  gfx.spr_ex(2, car.x, car.y, false, false, car.facing_angle - math.pi / 2, car_tint, 1)

  if ui.button("Restart", 8, 8) then reset_run() end

  if countdown_time > 0 then
    dim.draw(game_width, game_height)
    local text = tostring(math.ceil(countdown_time))
    local scale = 12
    local tw, th = usagi.measure_text(text)
    local x = math.floor((game_width - tw * scale) / 2)
    local y = math.floor((game_height - th * scale) / 2)
    gfx.text_ex(text, x + 2, y + 2, scale, 0, gfx.COLOR_BLACK, 0.8)
    gfx.text_ex(text, x, y, scale, 0, gfx.COLOR_WHITE, 1)
  end
end
