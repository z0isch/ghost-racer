local ui          = require "ui"
local dim         = require "dim"
local hud         = require "hud"
local economy     = require "economy"
local ghost       = require "ghost"
local track_data  = require "track_data"
local road        = require "road"
local popups      = require "popups"

local SHOP_COST_W = 50
local GHOST_ALPHA = 0.6

local M           = {}

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
end

local function shop_button(item, x, y, w)
  local kind       = item.kind
  local label      = item.label
  local cost       = economy.upgrade_cost(kind)

  local affordable = cost ~= nil and (cost == 0 or State.money >= cost)
  if kind == "ghosts" and not State.tracks[State.active_track].ghost_line then
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
  M.draw_shop()
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
    ui.rank_text(rank, rank, x + math.floor((w - usagi.measure_text(rank)) / 2), info_y, 1)
  end

  info_y = info_y + 13
  local you_earn_label = string.format("You earn $%d per Checkpoint and ©", economy.PAY)
  ui.coin_text(you_earn_label, x, info_y, 1, gfx.COLOR_LIGHT_GRAY)
  info_y = info_y + 13

  if State.tracks[State.active_track].ghosts > 0 then
    info_y                 = info_y + 3
    local ghost_earn_label = "Ghosts earn" .. string.format(" $%d per Checkpoint and ©", economy.PAY * rank_mult)
    ui.coin_text(ghost_earn_label, x, info_y, 1, gfx.COLOR_LIGHT_GRAY)
  end

  local shop_y = info_y + th_a + 6
  for _, item in ipairs(tdata.shop) do
    local clicked, bh = shop_button(item, x, shop_y, w)
    if clicked then economy.try_buy(item.kind) end
    shop_y = shop_y + bh + gap
  end

  local race_x = math.floor((usagi.GAME_W - w) / 2)
  if ui.button("RACE", race_x, usagi.GAME_H - 80, { w = w, scale = 3 }) then
    SceneGoto("race")
  end

  local next_track = nil
  for _, tid in ipairs(track_data.TRACK_ORDER) do
    if not State.unlocked[tid] then
      next_track = tid; break
    end
  end
  if next_track then
    local ntdata   = track_data.TRACKS[next_track]
    local cost     = ntdata.unlock_cost
    local can_buy  = State.money >= cost
    local btn_text = string.format("Buy %s - $%d", ntdata.label, cost)
    if ui.button(btn_text, math.floor((usagi.GAME_W - w) / 2), usagi.GAME_H - 42,
          { w = w, disabled = not can_buy }) then
      if economy.try_unlock_track(next_track) then
        State.active_track = next_track
      end
    end
  end
end

return M
