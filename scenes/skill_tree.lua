local ui         = require "ui"
local persist    = require "persist"
local skill_tree = require "skill_tree"
local car        = require "car"

local M = {}

function M.enter()
  -- Same guarantee as the other scenes: engine silence on every path in.
  car.stop_engine(State.car)
end

function M.exit() end

function M.update(_dt) end -- tree input is handled in draw (immediate-mode)

function M.draw()
  gfx.clear(gfx.COLOR_DARK_BLUE) -- match the dev harness backdrop
  local st    = State.skill_tree
  local stats = { loops = State.loop - 1 }

  -- Title + blurb, centered up top, clear of the ¥ HUD (top-left, drawn by
  -- skill_tree.draw) and the nodes (y >= ~124).
  local title   = "GARAGE"
  local t_scale = 3
  local title_w = usagi.measure_text(title) * t_scale
  gfx.text_ex(title, math.floor((usagi.GAME_W - title_w) / 2), 14, t_scale, 0, gfx.COLOR_WHITE, 1)
  local blurb   = "Spend ¥ to upgrade your car for the next loop"
  local blurb_w = usagi.measure_text(blurb)
  gfx.text_ex(blurb, math.floor((usagi.GAME_W - blurb_w) / 2), 46, 1, 0, gfx.COLOR_LIGHT_GRAY, 1)

  -- skill_tree.draw both renders and mutates on click (immediate-mode), and
  -- try_buy's return is swallowed inside it. Detect a purchase without
  -- touching the module by snapshotting points around the call.
  local points_before = st.points
  skill_tree.draw(st, stats)
  if st.points ~= points_before then
    persist.rederive_skill_effects()
    persist.resync_car_and_ghosts()
    persist.save()
  end

  -- NEXT button, gated until Engine Tune (top_speed) is bought at least once.
  local w     = 200
  local x     = math.floor((usagi.GAME_W - w) / 2)
  local y     = usagi.GAME_H - 60
  local gated = skill_tree.rank(st, "top_speed") == 0
  if ui.button("NEXT", x, y, { w = w, scale = 3, disabled = gated }) and not gated then
    SceneGoto("intro")
  end
  if gated then
    -- Always-visible popover, node-popover style (black 0.85 fill, white
    -- border), anchored just above the button.
    local msg    = "Buy Engine Tune to continue"
    local tw, th = usagi.measure_text(msg)
    local pad    = 4
    local bw     = tw + pad * 2
    local bx     = math.floor((usagi.GAME_W - bw) / 2)
    local by     = y - th - pad * 2 - 6
    gfx.rect_fill(bx, by, bw, th + pad * 2, gfx.COLOR_BLACK, 0.85)
    gfx.rect(bx, by, bw, th + pad * 2, gfx.COLOR_WHITE)
    gfx.text(msg, bx + pad, by + pad, gfx.COLOR_WHITE)
  end
end

return M
