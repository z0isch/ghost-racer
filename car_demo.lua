-- Scripted looping demos of the car's unlockable moves (drift, drift boost,
-- boost), shown inside the first-purchase modals (see scenes/buy.lua). Each
-- demo's pose is a pure function of the loop timer, so drawing needs no
-- update step: the skid trail is rebuilt every frame by sampling recent
-- poses instead of accumulating state like car.lua does.

local CAR_SPRITE = 2

-- Skid geometry matches car.lua's marks.
local SKID_BACK  = 5
local SKID_PERP  = 4
local SKID_AGE   = 1.0
local SKID_STEP  = 1 / 20

local GREEN_AT   = 0.6 -- drift seconds before the boost arms; matches car.drift_threshold
local PIP_DIST   = 14  -- boost pip trail distance; matches car.lua's BOOST_TRAIL_START

local M          = {}

M.W              = 208
M.H              = 80

local start_time = 0

-- Call when a modal opens so every demo starts at the top of its loop.
function M.reset()
  start_time = usagi.elapsed
end

-- Drift: endless donut around the center of the demo area.
local DRIFT_R    = 24
local DRIFT_RATE = 2.6
local SLIDE      = 0.55 -- how far the nose over-rotates past the velocity direction

local function drift_pose(t)
  local a = t * DRIFT_RATE
  return {
    x        = M.W / 2 + math.cos(a) * DRIFT_R,
    y        = M.H / 2 + math.sin(a) * DRIFT_R,
    facing   = a + math.pi / 2 + SLIDE,
    drifting = true,
  }
end

-- Drift boost: drift an arc until the green flash arms, then release into a
-- straight burst of speed that settles before the loop restarts.
local DB_R          = 18
local DB_CX         = 42
local DB_DRIFT_T    = 1.5
local DB_BOOST_T    = 0.8
local DB_COAST_T    = 0.5
local DB_PERIOD     = DB_DRIFT_T + DB_BOOST_T + DB_COAST_T
local DB_BOOST_V    = 130
local DB_COAST_V    = 50
local DB_STRAIGHTEN = 0.25 -- seconds to swing the nose back in line after release

local function drift_boost_pose(t)
  t = t % DB_PERIOD
  if t < DB_DRIFT_T then
    -- Clockwise arc ending at the bottom of the circle, where the exit
    -- direction points right for the straight run.
    local a = math.pi / 2 + DRIFT_RATE * (DB_DRIFT_T - t)
    return {
      x        = DB_CX + math.cos(a) * DB_R,
      y        = M.H / 2 + math.sin(a) * DB_R,
      facing   = a - math.pi / 2 - SLIDE,
      drifting = true,
      green    = t >= GREEN_AT,
    }
  end
  local run = t - DB_DRIFT_T
  local x   = DB_CX + math.min(run, DB_BOOST_T) * DB_BOOST_V
      + math.max(run - DB_BOOST_T, 0) * DB_COAST_V
  return {
    x      = x,
    y      = M.H / 2 + DB_R,
    facing = -SLIDE * math.max(0, 1 - run / DB_STRAIGHTEN),
  }
end

-- Boost: cruise right with a spare charge trailing behind, then spend it for
-- flames and a burst of speed.
local B_START_X = 12
local B_CRUISE_T = 1.0
local B_CRUISE_V = 50
local B_BOOST_T = 0.7
local B_BOOST_V = 140
local B_SETTLE_T = 0.5
local B_SETTLE_V = 70
local B_FLAME_T = 0.8 -- matches car.lua's BOOST_FLAME_TIME
local B_PERIOD = B_CRUISE_T + B_BOOST_T + B_SETTLE_T

local function boost_pose(t)
  t = t % B_PERIOD
  local x = B_START_X + math.min(t, B_CRUISE_T) * B_CRUISE_V
      + util.clamp(t - B_CRUISE_T, 0, B_BOOST_T) * B_BOOST_V
      + math.max(t - B_CRUISE_T - B_BOOST_T, 0) * B_SETTLE_V
  return {
    x      = x,
    y      = M.H / 2,
    facing = 0,
    flame  = t >= B_CRUISE_T and t < B_CRUISE_T + B_FLAME_T,
    pips   = t < B_CRUISE_T and 1 or 0,
  }
end

local POSES = {
  drift       = drift_pose,
  drift_boost = drift_boost_pose,
  boost       = boost_pose,
}

local function skid_points(x, y, p)
  local back = util.vec_from_angle(p.facing + math.pi, SKID_BACK)
  local perp = util.vec_from_angle(p.facing + math.pi / 2, SKID_PERP)
  local cx   = x + p.x + back.x
  local cy   = y + p.y + back.y
  return { lx = cx - perp.x, ly = cy - perp.y, rx = cx + perp.x, ry = cy + perp.y }
end

local function draw_skids(pose_fn, t, x, y)
  local prev
  for i = math.floor(SKID_AGE / SKID_STEP), 0, -1 do
    local ts  = t - i * SKID_STEP
    local p   = ts >= 0 and pose_fn(ts) or nil
    local cur = nil
    if p and p.drifting then
      cur = skid_points(x, y, p)
      if prev then
        local alpha = 1 - (i * SKID_STEP) / SKID_AGE
        gfx.line(prev.lx, prev.ly, cur.lx, cur.ly, gfx.COLOR_BLACK, alpha)
        gfx.line(prev.rx, prev.ry, cur.rx, cur.ry, gfx.COLOR_BLACK, alpha)
      end
    end
    prev = cur
  end
end

-- Boost flames, copied from car.draw_flames but anchored to a demo pose.
local function draw_flames(cx, cy, facing)
  local back   = facing + math.pi
  local flick  = 0.6 + 0.4 * math.abs(math.sin(usagi.elapsed * 40))
  local layers = {
    { len = 11 * flick, half = 4, color = gfx.COLOR_RED },
    { len = 8 * flick,  half = 3, color = gfx.COLOR_ORANGE },
    { len = 5 * flick,  half = 2, color = gfx.COLOR_YELLOW },
  }
  local perp   = facing + math.pi / 2
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

-- Draws one looping demo with its top-left corner at x, y. kind is a
-- FIRST_PURCHASE_MODAL_KINDS key: "drift", "drift_boost", or "boost".
function M.draw(kind, x, y)
  local pose_fn = POSES[kind]
  local t       = usagi.elapsed - start_time

  gfx.rect_fill(x, y, M.W, M.H, gfx.COLOR_INDIGO) -- road color

  draw_skids(pose_fn, t, x, y)

  local p  = pose_fn(t)
  local px = x + p.x
  local py = y + p.y

  if p.flame then draw_flames(px, py, p.facing) end

  for b = 1, p.pips or 0 do
    local q = util.vec_from_angle(p.facing + math.pi, PIP_DIST + (b - 1) * 10)
    gfx.circ_fill(px + q.x, py + q.y, 3, gfx.COLOR_ORANGE, 1)
  end

  local tint = gfx.COLOR_WHITE
  if p.green then
    tint = util.flash(usagi.elapsed, 8) and gfx.COLOR_WHITE or gfx.COLOR_GREEN
  end
  gfx.spr_ex(CAR_SPRITE, px - 8, py - 8, false, false, p.facing - math.pi / 2, tint, 1)
end

return M
