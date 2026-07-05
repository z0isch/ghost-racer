local ui          = require "ui"
local dim         = require "dim"
local hud         = require "hud"
local economy     = require "economy"
local ghost       = require "ghost"
local track_data  = require "track_data"
local road        = require "road"
local popups      = require "popups"
local modal       = require "modal"
local car_demo    = require "car_demo"

local SHOP_COST_W = 50
local GHOST_ALPHA = 0.6

-- First-purchase explainer copy, keyed by shop `kind`. Shown once as an
-- overlay in this scene immediately on purchase (see economy.try_buy).
local MODAL_INFO  = {
  ghosts = {
    title = "Ghost Unlocked!",
    body  = function()
      return
      "A ghost repeats your best lap\nforever, banking cash at every\ncheckpoint - even while you're away!"
    end,
  },
  coins = {
    title = ui.COIN_CHAR .. " Unlocked!",
    body  = function()
      return ui.COIN_CHAR ..
          " pay cash whenever you or a ghost drives\nthrough them."
    end,
  },
  drift = {
    title = "Drift Unlocked!",
    body  = function()
      return "Hold " .. input.mapping_for(input.BTN2) .. " while turning\nto slide around corners."
    end,
  },
  drift_boost = {
    title = "Drift Boost Unlocked!",
    body  = function()
      return "Drift long enough, then release\n" .. input.mapping_for(input.BTN2)
          .. " for a burst of speed.\nA green flash means it's armed."
    end,
  },
  boost = {
    title = "Boost Unlocked!",
    body  = function()
      return "Press " .. input.mapping_for(input.BTN3) .. " to spend a charge\nfor an instant burst of speed.\n"
          .. "One charge per rank, per race."
    end,
  },
}

local M           = {}

-- Which kind the demo loop was last reset for, so it restarts per modal.
local demo_kind

function M.enter()
  ghost.reset_all_phases()
end

function M.exit()
end

function M.update(dt)
  ghost.update(dt)
  for _, ev in ipairs(ghost.collect_crossings()) do
    economy.bank(ev)
  end
  popups.update(dt)
  if State.purchase_modal and input.pressed(input.BTN1) then
    State.purchase_modal = nil
  end
  if State.race_modal and input.pressed(input.BTN1) then
    State.race_modal = nil
  end
end

local function shop_button(item, x, y, w)
  local kind       = item.kind
  local label      = item.label
  local cost       = economy.upgrade_cost(kind)

  local affordable = cost ~= nil and (cost == 0 or State.money >= cost)
  if kind == "ghosts" and not State.tracks[State.active_track].ghost_line then
    affordable = false
  end
  if kind == "drift_boost" and State.drift == 0 then
    affordable = false
  end

  local cost_text, cost_color
  if cost == nil then
    cost_text = "MAX"
  elseif cost == 0 then
    cost_text = "FREE"
  else
    cost_text  = "$" .. tostring(cost)
    cost_color = affordable and gfx.COLOR_GREEN or gfx.COLOR_LIGHT_GRAY
  end

  local _, th = usagi.measure_text(label)
  local bh    = th * 2 + 4

  ui.label(label, x, y + math.floor((bh - th * 2) / 2))

  local bx       = x + w - SHOP_COST_W
  local btn_opts = { w = SHOP_COST_W, disabled = not affordable, text = cost_color, dim_text = cost_color }
  local clicked  = ui.button(cost_text, bx, y, btn_opts)
  return clicked, bh
end

local function new_track_row(track_id, next_id, next_track_idx, x, y, w)
  local label = string.format("Track #%d", next_track_idx)
  local _, th = usagi.measure_text(label)
  local bh    = th * 2 + 4
  ui.label(label, x, y + math.floor((bh - th * 2) / 2))

  if not economy.a_rank_earned(track_id) then
    local msg = "RANK A needed"
    local mw  = usagi.measure_text(msg)
    local mx  = x + w + usagi.measure_text(label) - mw
    local my  = y + math.floor((bh - th) / 2)
    ui.label(msg, mx, my, { scale = 1, color = gfx.COLOR_LIGHT_GRAY })
    return false, bh
  end

  local cost       = track_data.TRACKS[next_id].unlock_cost
  local affordable = State.money >= cost
  local cost_text  = "$" .. tostring(cost)
  local cost_color = affordable and gfx.COLOR_GREEN or gfx.COLOR_LIGHT_GRAY
  local bx         = x + w - SHOP_COST_W
  local btn_opts   = { w = SHOP_COST_W, disabled = not affordable, text = cost_color, dim_text = cost_color }
  local clicked    = ui.button(cost_text, bx, y, btn_opts)
  return clicked, bh
end

function M.draw()
  local id    = State.active_track
  local tdata = track_data.TRACKS[id]
  road.draw_track(tdata.map)
  dim.draw(usagi.GAME_W, usagi.GAME_H)

  local checkpoints = tdata.checkpoints
  for i, cp in ipairs(checkpoints) do
    road.draw_checkpoint(cp, i, true, #checkpoints)
  end
  road.draw_coins(tdata.coins, State.tracks[id].coins)
  ghost.draw_sim(GHOST_ALPHA)
  popups.draw()
  hud.draw()
  if State.race_modal then
    M.draw_race_modal()
  elseif State.purchase_modal then
    M.draw_purchase_modal()
  else
    M.draw_shop()
  end
end

function M.draw_purchase_modal()
  local kind = State.purchase_modal
  if kind ~= demo_kind then
    demo_kind = kind
    car_demo.reset()
  end
  local info = MODAL_INFO[kind]
  local demo
  if car_demo.supports(kind) then
    demo = {
      w    = car_demo.W,
      h    = car_demo.H,
      draw = function(x, y) car_demo.draw(kind, x, y) end,
    }
  end
  if modal.draw({ title = info.title, body = info.body(), demo = demo }) then
    State.purchase_modal = nil
  end
end

-- Post-race modal: shown after the very first lap on a track (explains the
-- beat-your-lap loop) and after any lap that raised the track's rank (shows
-- the pay-rate changes). See scenes/race.lua finish_race().
function M.draw_race_modal()
  local info  = State.race_modal
  local id    = info.track_id
  local title = "RANK " .. info.rank .. (info.prev_rank and "!" or "")

  local body
  if info.prev_rank then
    local prev_mult = economy.RANK_MULTS[info.prev_rank]
    local new_mult  = economy.RANK_MULTS[info.rank]
    body            = string.format("Your Rate:  $%d -> $%d",
      economy.pay_for_mult(id, prev_mult), economy.pay_for_mult(id, new_mult))
    if State.tracks[id].ghosts > 0 then
      local pay = economy.track_pay(id)
      body = body .. string.format("\nGhost Rate: $%d -> $%d",
        math.floor(pay * prev_mult + 0.5), math.floor(pay * new_mult + 0.5))
    end
  else
    body = "Lap saved! Beat it to raise\nyour rank and pay rates."
  end

  if info.show_unlock then
    body = body .. "\n\nNew track available in the shop!"
  end

  local bang       = info.prev_rank and "!" or ""
  local draw_title = function(x, y, scale)
    local rx = x
    rx = rx + ui.coin_text("RANK ", rx, y, scale, gfx.COLOR_WHITE)
    rx = rx + ui.rank_text(info.rank, info.rank, rx, y, scale)
    if bang ~= "" then
      ui.coin_text(bang, rx, y, scale, gfx.COLOR_WHITE)
    end
  end

  if modal.draw({ title = title, body = body, draw_title = draw_title }) then
    State.race_modal = nil
  end
end

function M.draw_shop()
  local x       = 8
  local w       = 200
  local gap     = 6

  local id      = State.active_track
  local idx     = track_data.get_track_index(id)
  local tdata   = track_data.TRACKS[id]
  local _, th_a = usagi.measure_text("A")
  local nav_y   = 50
  local arrow_w = 18

  if idx > 1 then
    if ui.button("<", x, nav_y, { w = arrow_w }) then
      State.active_track = track_data.TRACK_ORDER[idx - 1]
    end
  end
  if idx < #track_data.TRACK_ORDER and State.unlocked[track_data.TRACK_ORDER[idx + 1]] then
    if ui.button(">", x + w - arrow_w, nav_y, { w = arrow_w }) then
      State.active_track = track_data.TRACK_ORDER[idx + 1]
    end
  end

  local lbl_text = tdata.label
  local lbl_w    = usagi.measure_text(lbl_text) * 2
  gfx.text_ex(lbl_text, x + math.floor((w - lbl_w) / 2), nav_y + 2, 2, 0, gfx.COLOR_WHITE, 1)

  local info_y    = nav_y + th_a * 2
  local rank      = economy.track_rank(id)
  local rank_mult = economy.RANK_MULTS[rank]
  if State.tracks[id].ghost_line then
    ui.rank_text(rank, rank, x + math.floor((w - usagi.measure_text(rank)) / 2), info_y, 2)
    info_y = info_y + th_a * 2 + 2
    if State.tracks[id].ghosts > 0 then
      local track_rate_text = string.format("$%.2f/sec", economy.track_cash_rate(id))
      local track_rate_w    = usagi.measure_text(track_rate_text)
      gfx.text_ex(track_rate_text, x + math.floor((w - track_rate_w) / 2), info_y, 1, 0, gfx.COLOR_LIGHT_GRAY, 1)
      info_y = info_y + th_a + 6
    end
  else
    info_y = info_y + 20
  end

  local you_earn_label = string.format("Your Rate:  $%d", economy.player_pay(id))
  ui.coin_text(you_earn_label, x, info_y, 1, gfx.COLOR_LIGHT_GRAY)
  info_y = info_y + 13

  if State.tracks[State.active_track].ghosts > 0 then
    info_y                 = info_y + 3
    local ghost_earn_label = string.format("Ghost Rate: $%d", tdata.pay * rank_mult)
    ui.coin_text(ghost_earn_label, x, info_y, 1, gfx.COLOR_LIGHT_GRAY)
  end

  local shop_y = info_y + th_a + 6
  for _, item in ipairs(tdata.shop) do
    local clicked, bh = shop_button(item, x, shop_y, w)
    if clicked then economy.try_buy(item.kind) end
    shop_y = shop_y + bh + gap
  end

  local next_track = idx < #track_data.TRACK_ORDER and track_data.TRACK_ORDER[idx + 1] or nil
  if next_track and not State.unlocked[next_track] then
    local clicked, bh = new_track_row(id, next_track, idx + 1, x, shop_y, w)
    if clicked and economy.try_unlock_track(next_track) then
      State.active_track = next_track
    end
    shop_y = shop_y + bh + gap
  end

  local race_x = math.floor((usagi.GAME_W - w) / 2)
  if ui.button("RACE", race_x, usagi.GAME_H - 40, { w = w, scale = 3 }) then
    SceneGoto("race")
  end
end

return M
