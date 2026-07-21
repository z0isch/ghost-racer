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
local car         = require "car"
local gates       = require "gates"
local persist     = require "persist"

local SHOP_COST_W = 50
local GHOST_ALPHA = 0.6

-- Formats a duration in seconds as H:MM:SS (or M:SS under an hour).
local function format_duration(seconds)
  local total = math.floor(seconds + 0.5)
  local h     = math.floor(total / 3600)
  local m     = math.floor((total % 3600) / 60)
  local s     = total % 60
  if h > 0 then
    return string.format("%d:%02d:%02d", h, m, s)
  end
  return string.format("%d:%02d", m, s)
end

-- First-purchase explainer copy, keyed by shop `kind`. Shown once as an
-- overlay in this scene immediately on purchase (see economy.try_buy).
local MODAL_INFO = {
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
  checkpoints = {
    title = "Checkpoint Unlocked!",
    body  = function()
      return "The race now runs to the newest\ncheckpoint - a longer course\nwith a higher rank ceiling!"
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
  magnet = {
    title = "Coin Magnet Unlocked!",
    body  = function()
      return
          "Pulls in " .. ui.COIN_CHAR .. " from a larger radius\naround your car."
    end,
  },
  nirvana = {
    title   = "Loop Complete!",
    rainbow = true,
    button  = "OKAY",
    body    = function()
      return "Unfortunately you have not escaped the endless loop.\nGo FASTER to increase your rank and escape SAMSARA!"
    end,
  },
}

-- Two-step explainer shown once, right after the first race of loop 2 (the
-- first loop where the tachometer appears - see finish_race). Step 1 teaches
-- the loop rank / tachometer with a shrunk copy of the dial; step 2 sets the
-- S-rank win condition. Sequenced via State.loop_intro (1, then 2, then nil).
local LOOP_INTRO = {
  {
    title = "Loop Rank",
    body  = "This gauge is your Loop Rank - the\npace to finish the whole loop.\n\n"
        .. "Faster loops earn a higher Rank,\nand higher Ranks pay more ¥.",
    demo  = true,
  },
  {
    title = "Escape SAMSARA",
    body  = "Reach Rank S on a loop to break\nfree and escape SAMSARA for good.\n\n"
        .. "Anything less and the loop\nbegins anew...",
  },
}

-- Clears the purchase modal; dismissing Nirvana also returns to the title
-- screen, since there's nothing left to buy.
local function dismiss_purchase_modal()
  local kind           = State.purchase_modal
  State.purchase_modal = nil
  if kind == "nirvana" then SceneGoto("skill_tree") end
end

-- Tachometer of the current loop's provisional rank - what finishing right
-- now would rate. The needle climbs from S at the left, through A/B/C, to the
-- redline D on the right as loop time burns; the wedge it sits in lights up in
-- its rank color while the rest gray out (the same zone scheme as the race
-- HUD's rank bar). Ticking pressure: finish before the needle crosses into the
-- next wedge. A digital clock reads out below. Hidden during the loop-1
-- prologue, where the awarded rank is pinned to D and the dial would confuse.
local TACH_ZONES  = { "S", "A", "B", "C", "D" } -- dial order, f=0 to f=1
local TACH_START  = math.rad(210)               -- f=0 angle, lower-left
local TACH_SPAN   = math.rad(240)               -- clockwise sweep to lower-right
local TACH_R      = 62                          -- band radius
local TACH_STEPS  = 60                          -- chords stepped along the arc
local TACH_CY     = 156                         -- dial center y
local TACH_LSCALE = 2                           -- wedge-letter text scale

-- Screen-space point at needle fraction `f` (0 = S end, 1 = redline) on a
-- circle of radius `r` centered at (cx, cy).
local function tach_point(f, r, cx, cy)
  local a = TACH_START - f * TACH_SPAN
  return cx + math.cos(a) * r, cy - math.sin(a) * r
end

-- Draws the tachometer dial for loop time `seconds`, centered at (cx, cy) with
-- band radius `r`. All other dimensions scale off `r` via opts so the same dial
-- renders full-size on the buy screen and shrunk inside the loop-rank tutorial
-- modal. opts: band_w (band chord width), lscale (rank-letter text scale),
-- letter_r (letter ring radius), hub_r (hub outer radius).
local function draw_tach(cx, cy, r, seconds, opts)
  opts              = opts or {}
  local band_w      = opts.band_w or 7
  local lscale      = opts.lscale or TACH_LSCALE
  local letter_r    = opts.letter_r or (r + 20)
  local hub_r       = opts.hub_r or 5
  local pos, rank   = track_data.loop_rank_gauge(seconds)
  local active_zone = math.min(math.floor(pos * 5) + 1, 5)

  -- Zone band: short thick chords stepped along the arc. Only the needle's
  -- wedge shows its rank color (rainbow shimmer for S); the rest gray out.
  for s = 0, TACH_STEPS - 1 do
    local f0     = s / TACH_STEPS
    local f1     = (s + 1) / TACH_STEPS
    local zi     = math.min(math.floor((f0 + f1) / 2 * 5) + 1, 5)
    local color  = zi == active_zone and ui.rank_color(TACH_ZONES[zi], s)
        or gfx.COLOR_DARK_GRAY
    local x0, y0 = tach_point(f0, r, cx, cy)
    local x1, y1 = tach_point(f1, r, cx, cy)
    gfx.line_ex(x0, y0, x1, y1, band_w, color, 1)
  end

  -- Tick marks at the wedge boundaries.
  for i = 0, 5 do
    local x0, y0 = tach_point(i / 5, r - 6, cx, cy)
    local x1, y1 = tach_point(i / 5, r + 5, cx, cy)
    gfx.line_ex(x0, y0, x1, y1, 1, gfx.COLOR_WHITE, 1)
  end

  -- Rank letter just outside each wedge; the needle's wedge stands out white
  -- while the others dim, matching the HUD bar's held-still labels.
  for zi = 1, 5 do
    local letter = TACH_ZONES[zi]
    local lw, lh = usagi.measure_text(letter)
    local lx, ly = tach_point((zi - 0.5) / 5, letter_r, cx, cy)
    lx           = math.floor(lx - lw * lscale / 2)
    ly           = math.floor(ly - lh * lscale / 2)
    local color  = zi == active_zone and gfx.COLOR_WHITE or gfx.COLOR_LIGHT_GRAY
    local alpha  = zi == active_zone and 1 or 0.5
    gfx.text_ex(letter, lx + 1, ly + 1, lscale, 0, gfx.COLOR_BLACK, alpha)
    gfx.text_ex(letter, lx, ly, lscale, 0, color, alpha)
  end

  -- Needle from the hub out to just under the band, plus a rank-colored hub.
  local nx, ny = tach_point(pos, r - 8, cx, cy)
  gfx.line_ex(nx + 1, ny + 1, cx + 1, cy + 1, 2, gfx.COLOR_BLACK, 0.5)
  gfx.line_ex(nx, ny, cx, cy, 2, gfx.COLOR_WHITE, 1)
  gfx.circ_fill(cx, cy, hub_r, gfx.COLOR_BLACK, 1)
  gfx.circ_fill(cx, cy, hub_r - 2, ui.rank_color(rank, 0), 1)
end

local function draw_loop_status()
  if State.loop == 1 then return end
  local seconds = State.loop_time or 0
  local cx      = math.floor(usagi.GAME_W / 2)
  local cy      = TACH_CY
  draw_tach(cx, cy, TACH_R, seconds)

  -- Digital clock readout below the dial.
  local scale     = 3
  local time_text = format_duration(seconds)
  local tw        = usagi.measure_text(time_text)
  local tx        = math.floor((usagi.GAME_W - tw * scale) / 2)
  local ty        = cy + 44
  gfx.text_ex(time_text, tx + 1, ty + 1, scale, 0, gfx.COLOR_BLACK, 1)
  gfx.text_ex(time_text, tx, ty, scale, 0, gfx.COLOR_WHITE, 1)
end

-- Small tachometer for the loop-rank tutorial modal's demo slot. Sized so the
-- dial and its outer rank letters fit inside a compact box; the needle reads
-- the live loop time, matching the full dial drawn behind the modal.
local TACH_DEMO_W  = 128
local TACH_DEMO_H  = 78
local TACH_DEMO_R  = 34
local TACH_DEMO_CY = 54 -- dial center offset from the demo box's top edge

local function draw_tach_demo(x, y)
  draw_tach(x + math.floor(TACH_DEMO_W / 2), y + TACH_DEMO_CY, TACH_DEMO_R,
    State.loop_time or 0, { band_w = 4, lscale = 1, letter_r = TACH_DEMO_R + 12, hub_r = 4 })
end

local M = {}

-- Which kind the demo loop was last reset for, so it restarts per modal.
local demo_kind

-- Applause follows the Nirvana fanfare once it finishes, rather than
-- overlapping it (see economy.try_buy). Edge-triggered on the fanfare
-- ending rather than tied to the modal, since the modal only re-arms via
-- demo_kind on the very first Nirvana purchase (seen_modals carries the
-- kind across loops after that).
local loop_complete_was_playing = false

function M.enter()
  -- Guarantees engine silence on every path in, including dev live-reload
  -- and Reset, which keep the music channel playing across _init.
  car.stop_engine(State.car)
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
  local loop_complete_playing = sfx.is_playing("loop_complete")
  if loop_complete_was_playing and not loop_complete_playing then
    sfx.play("applause")
  end
  loop_complete_was_playing = loop_complete_playing
  if State.purchase_modal and input.pressed(input.BTN1) then
    dismiss_purchase_modal()
  end
  if State.race_modal and input.pressed(input.BTN1) then
    State.race_modal = nil
  end
  -- Only advance the tutorial once the post-race modal is cleared, so a single
  -- press can't skip past both at once (draw shows race_modal first).
  if not State.race_modal and State.loop_intro and input.pressed(input.BTN1) then
    M.advance_loop_intro()
  end
  if not State.purchase_modal and not State.race_modal and not State.loop_intro and input.key_pressed(input.KEY_SPACE) then
    SceneGoto("race")
  end
end

-- One shop row: label left, cost button right. opts.cost_w widens the cost
-- button (the upgrades column needs room for 5-digit prices).
local function shop_button(item, x, y, w, opts)
  opts         = opts or {}
  local cost_w = opts.cost_w or SHOP_COST_W
  local kind   = item.kind
  local label  = item.label
  local cost   = economy.upgrade_cost(kind)

  local locked_msg
  if not economy.shop_item_unlocked(State.active_track, item) then
    locked_msg = item.requires_rank_all
        and ("RANK " .. item.requires_rank_all .. " on all tracks")
        or ("RANK " .. item.requires_rank .. " needed")
  elseif economy.needs_first_race(State.active_track, kind) then
    locked_msg = "Complete 1 race"
  end
  if locked_msg then
    local _, th = usagi.measure_text(label)
    local bh    = th * 2 + 4
    ui.label(label, x, y + math.floor((bh - th * 2) / 2))
    local mw = usagi.measure_text(locked_msg)
    local mx = x + w + usagi.measure_text(label) - mw
    ui.label(locked_msg, mx, y + math.floor((bh - th) / 2), { scale = 1, color = gfx.COLOR_LIGHT_GRAY })
    return false, bh
  end

  local affordable = cost ~= nil and (cost == 0 or State.money >= cost)
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

  local bx       = x + w - cost_w
  local btn_opts = { w = cost_w, disabled = not affordable, text = cost_color, dim_text = cost_color }
  local clicked  = ui.button(cost_text, bx, y, btn_opts)
  return clicked, bh
end

local function new_track_row(next_id, next_track_idx, x, y, w)
  local label = string.format("Track #%d", next_track_idx)
  local _, th = usagi.measure_text(label)
  local bh    = th * 2 + 4
  ui.label(label, x, y + math.floor((bh - th * 2) / 2))

  if not economy.track_unlock_ready(next_id) then
    local msg = track_data.TRACKS[next_id].unlock_needs_all_s
        and "RANK S on all tracks"
        or ("RANK " .. track_data.unlock_rank(State.loop) .. " needed")
    local mw  = usagi.measure_text(msg)
    local mx  = x + w + usagi.measure_text(label) - mw
    local my  = y + math.floor((bh - th) / 2)
    ui.label(msg, mx, my, { scale = 1, color = gfx.COLOR_LIGHT_GRAY })
    return false, bh
  end

  local cost       = track_data.unlock_cost(next_id, State.loop)
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

  -- Nil car: backdrop preview, every gate at the neutral "open" alpha.
  if tdata.gates and gates.enabled(State.car) then
    gates.draw(tdata.gates, nil)
  end
  local checkpoints = tdata.checkpoints
  for i, cp in ipairs(checkpoints) do
    road.draw_checkpoint(cp, i, true, #checkpoints, i > economy.owned_cps(id))
  end
  road.draw_coins(tdata.coins, State.tracks[id].coins)
  ghost.draw_sim(GHOST_ALPHA)
  popups.draw()
  hud.draw()
  draw_loop_status()
  if State.race_modal then
    M.draw_race_modal()
  elseif State.loop_intro then
    M.draw_loop_intro()
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
  local draw_title
  if info.rainbow then
    draw_title = function(x, y, scale) ui.rank_text(info.title, "S", x, y, scale) end
  end
  if modal.draw({ title = info.title, body = info.body(), demo = demo, draw_title = draw_title, draw_body = info.draw_body, button = info.button }) then
    dismiss_purchase_modal()
  end
end

-- Post-race modal: shown after the very first lap on a track (explains the
-- beat-your-lap loop), after any lap that raised the track's rank (shows the
-- pay-rate changes), and/or after a lap that raised the track's ghost $/sec
-- (shows that rate's change). All three can coincide on one lap; they share
-- this single modal rather than stacking separate popups. See
-- scenes/race.lua finish_race().
function M.draw_race_modal()
  local info         = State.race_modal
  local id           = info.track_id
  local rank_changed = info.prev_rank ~= nil
  -- A cash-only bump (no rank change, not the first-lap explainer) hides the
  -- rank entirely rather than showing a bare, unchanged "RANK X".
  local show_rank    = info.first_lap or rank_changed

  local body_parts   = {}

  -- The run's raw inputs come first, right under the rank title: rank is
  -- $/sec, so time and coins are the two levers the player pulls to raise it.
  local stats        = string.format("Time: %.1fs", info.time)
  if info.coins_total then
    stats = stats .. string.format("  %s %d/%d", ui.COIN_CHAR, info.coins_got, info.coins_total)
  end
  body_parts[#body_parts + 1] = stats

  if info.first_lap then
    body_parts[#body_parts + 1] = "Lap saved! Beat it to raise\nyour rank and pay rates."
  elseif rank_changed then
    local prev_mult = economy.RANK_MULTS[info.prev_rank]
    local new_mult  = economy.RANK_MULTS[info.rank]
    local line      = string.format("Your Rate:  $%d -> $%d",
      economy.pay_for_mult(id, prev_mult), economy.pay_for_mult(id, new_mult))
    if State.tracks[id].ghosts > 0 then
      local pay = economy.track_pay(id)
      line = line .. string.format("\nGhost Rate: $%d -> $%d",
        math.floor(pay * prev_mult + 0.5), math.floor(pay * new_mult + 0.5))
    end
    body_parts[#body_parts + 1] = line
  end

  if info.cash_after then
    body_parts[#body_parts + 1] = string.format("$/sec: $%.2f -> $%.2f", info.cash_before, info.cash_after)
  end

  -- New tracks are bought from the previous track's shop page, hence the -1.
  -- Both messages only name the shop's track when the player isn't already
  -- viewing it.
  if info.show_unlock then
    local idx = track_data.get_track_index(info.show_unlock)
    body_parts[#body_parts + 1] = track_data.get_track_index(State.active_track) == idx - 1
        and string.format("Track #%d available in the shop!", idx)
        or string.format("Track #%d available in\nTrack #%d's shop!", idx, idx - 1)
  end

  if info.show_nirvana then
    body_parts[#body_parts + 1] = State.active_track == info.show_nirvana
        and "Nirvana available in the shop!"
        or string.format("Nirvana available in\nTrack #%d's shop!",
          track_data.get_track_index(info.show_nirvana))
  end

  local body = table.concat(body_parts, "\n\n")

  local title, draw_title
  if show_rank then
    title      = "RANK " .. info.rank .. (rank_changed and "!" or "")
    draw_title = function(x, y, scale)
      local rx = x
      rx = rx + ui.coin_text("RANK ", rx, y, scale, gfx.COLOR_WHITE)
      rx = rx + ui.rank_text(info.rank, info.rank, rx, y, scale)
      if rank_changed then
        ui.coin_text("!", rx, y, scale, gfx.COLOR_WHITE)
      end
    end
  else
    title = "$/SEC INCREASE!"
  end

  if modal.draw({ title = title, body = body, draw_title = draw_title }) then
    State.race_modal = nil
  end
end

-- Draws the current loop-rank tutorial step (see LOOP_INTRO). Advancing past
-- the last step clears State.loop_intro, dropping back to the shop.
function M.draw_loop_intro()
  local step = LOOP_INTRO[State.loop_intro]
  local demo
  if step.demo then
    demo = { w = TACH_DEMO_W, h = TACH_DEMO_H, draw = draw_tach_demo }
  end
  if modal.draw({ title = step.title, body = step.body, demo = demo }) then
    M.advance_loop_intro()
  end
end

-- Steps the loop-rank tutorial forward, clearing it once past the last modal.
function M.advance_loop_intro()
  State.loop_intro = State.loop_intro + 1
  if State.loop_intro > #LOOP_INTRO then State.loop_intro = nil end
end

function M.draw_shop()
  local x       = 8
  local w       = 200
  local gap     = 6

  local id      = State.active_track
  local idx     = track_data.get_track_index(id)
  local order   = track_data.track_order(State.loop)
  local tdata   = track_data.TRACKS[id]
  local _, th_a = usagi.measure_text("A")
  local nav_y   = 50
  local arrow_w = 18

  if idx > 1 then
    if ui.button("<", x, nav_y, { w = arrow_w }) then
      State.active_track = order[idx - 1]
    end
  end
  if idx < #order and State.unlocked[order[idx + 1]] then
    if ui.button(">", x + w - arrow_w, nav_y, { w = arrow_w }) then
      State.active_track = order[idx + 1]
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
  for _, item in ipairs(track_data.shop(id, State.loop)) do
    -- Checkpoint Pass (skill tree) grants every checkpoint outright, so
    -- there's nothing left for this row to sell.
    if not (item.kind == "checkpoints" and State.unlock_checkpoints) then
      local clicked, bh = shop_button(item, x, shop_y, w)
      if clicked then economy.try_buy(item.kind) end
      shop_y = shop_y + bh + gap
    end
  end

  local next_track = idx < #order and order[idx + 1] or nil
  if next_track and not State.unlocked[next_track] then
    local clicked, bh = new_track_row(next_track, idx + 1, x, shop_y, w)
    if clicked and economy.try_unlock_track(next_track) then
      State.active_track = next_track
    end
    shop_y = shop_y + bh + gap
  end

  -- Global car-upgrades column, mirrored on the right edge. Wider cost
  -- buttons than the track shop so 5-digit prices fit.
  local uw     = 230
  local ux     = usagi.GAME_W - uw - 20
  local header = "Car Upgrades"
  local hw     = usagi.measure_text(header) * 2
  gfx.text_ex(header, ux + math.floor((uw - hw) / 2), nav_y + 10, 2, 0, gfx.COLOR_WHITE, 1)
  local uy = nav_y + th_a * 2 + 16
  for _, item in ipairs(track_data.upgrades(State.loop)) do
    local clicked, bh = shop_button(item, ux, uy, uw, { cost_w = 70 })
    if clicked then economy.try_buy(item.kind) end
    uy = uy + bh + gap
  end

  local race_x = math.floor((usagi.GAME_W - w) / 2)
  if ui.button("RACE", race_x, usagi.GAME_H - 60, { w = w, scale = 3 }) then
    SceneGoto("race")
  end
end

return M
