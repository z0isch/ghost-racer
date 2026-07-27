local ui                 = require "ui"
local persist            = require "persist"
local skill_tree         = require "skill_tree"
local car                = require "car"
local modal              = require "modal"

local M                  = {}

-- First-ever garage visit: a one-shot explainer that the garage sells
-- permanent, cross-loop upgrades bought with ¥ (a currency distinct from the
-- race $ spent in the shop). The ¥ is earned by racing well - each track's best
-- rank banks ¥ (see economy.bank_race_yen), spent here between loops. Gated on
-- State.seen_modals.garage, which persists across loops.
local GARAGE_MODAL_TITLE = "Welcome to the Garage!"
local GARAGE_MODAL_BODY  = table.concat({
  "Buy permanent upgrades that stay",
  "with you across every loop.",
  "",
  "Spend ¥ - earned by racing well,",
  "the better a track's rank the more",
  "it banks - then climb back stronger.",
}, "\n")

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

  -- First-visit explainer, drawn over the cleared backdrop instead of the
  -- tree so a dismiss click can't fall through onto a node. Persist the flag
  -- on dismiss so it never shows again.
  if not State.seen_modals.garage then
    if modal.draw({ title = GARAGE_MODAL_TITLE, body = GARAGE_MODAL_BODY }) then
      State.seen_modals.garage = true
      persist.save()
    end
    return
  end

  -- Title + blurb, centered up top, clear of the ¥ HUD (top-left, drawn by
  -- skill_tree.draw) and the nodes (y >= ~124).
  local title   = "GARAGE"
  local t_scale = 3
  local title_w = usagi.measure_text(title) * t_scale
  gfx.text_ex(title, math.floor((usagi.GAME_W - title_w) / 2), 14, t_scale, 0, gfx.COLOR_WHITE, 1)
  local blurb   = "Spend ¥ to upgrade your car for the next loop"
  local blurb_w = usagi.measure_text(blurb)
  gfx.text_ex(blurb, math.floor((usagi.GAME_W - blurb_w) / 2), 46, 1, 0, gfx.COLOR_LIGHT_GRAY, 1)

  -- skill_tree.draw both renders and mutates on click (immediate-mode); it
  -- reports a purchase itself. A points snapshot wouldn't do - Loose Change is
  -- free, so a buy can leave the balance untouched.
  if skill_tree.draw(st, stats) then
    persist.rederive_skill_effects()
    persist.resync_car_and_ghosts()
    persist.save()
  end

  -- NEXT button, gated until Loose Change (coins) is bought at least once - the
  -- forced buy of this garage, which the player first reaches after loop 2 with
  -- every other node locked. Only gated while it's actually affordable, so a
  -- player who Rebirthed with too little ¥ to buy anything (all-D races bank
  -- none) isn't trapped in the garage; Loose Change is free today, so the clause
  -- is insurance against a future reprice.
  local w        = 200
  local x        = math.floor((usagi.GAME_W - w) / 2)
  local y        = usagi.GAME_H - 60
  local g_cost   = skill_tree.next_cost(st, "coins")
  local gated    = skill_tree.rank(st, "coins") == 0
      and g_cost ~= nil and st.points >= g_cost
  if ui.button("NEXT", x, y, { w = w, scale = 3, disabled = gated }) and not gated then
    SceneGoto("intro")
  end
  if gated then
    -- Always-visible popover, node-popover style (black 0.85 fill, white
    -- border), anchored just above the button.
    local msg    = "Buy Loose Change to continue"
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
