local ui               = require "ui"
local dim              = require "dim"
local hud              = require "hud"
local economy          = require "economy"
local ghost            = require "ghost"
local track_data       = require "track_data"
local road             = require "road"
local popups           = require "popups"
local modal            = require "modal"
local car_demo         = require "car_demo"
local car              = require "car"
local gates            = require "gates"
local persist          = require "persist"

local SHOP_COST_W      = 50
local GHOST_ALPHA      = 0.6

-- First-purchase explainer copy, keyed by shop `kind`. Shown once as an
-- overlay in this scene immediately on purchase (see economy.try_buy).
local MODAL_INFO       = {
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
  rebirth = {
    title   = "Loop Complete!",
    rainbow = true,
    button  = "OKAY",
    body    = function()
      local body = "You have not escaped the\nendless loop of SAMSARA..."
      return body
    end,
  },
}

-- First-wall onboarding: shown once the first time a Rebirth becomes
-- affordable. Teaches the loop shape - you've unlocked every track you can this
-- loop, so Rebirth from the top track to reset and open the next one. Gated on
-- State.seen_modals.first_wall (persists across loops).
local FIRST_WALL_TITLE = "Hit a Wall?"
local FIRST_WALL_BODY  = table.concat({
  "Buy Rebirth to restart the loop."
}, "\n")

-- Clears the purchase modal. Dismissing the "Loop Complete!" fanfare drops into
-- the garage (skill tree) - the between-loops spend, and the only thing left to
-- do once the loop has reset.
local function dismiss_purchase_modal()
  local kind           = State.purchase_modal
  State.purchase_modal = nil
  if kind == "rebirth" then
    SceneGoto("skill_tree")
  end
end

-- Dismissing the TIME'S UP breakdown fires the forced Rebirth: the timeout
-- variant of start_new_loop (no fanfare), then drops into the garage. This is
-- the *unconditional* Rebirth - it calls start_new_loop directly, bypassing
-- economy.prestige()'s ceiling-track / affordability guards. Banked ¥ already
-- lives in the skill tree (bank_race_yen), so only in-loop money and track
-- ownership reset.
local function dismiss_timeout()
  State.loop_timeout = nil
  persist.start_new_loop({ timeout = true })
  SceneGoto("skill_tree")
end

local M = {}

-- Which kind the demo loop was last reset for, so it restarts per modal.
local demo_kind

-- Applause follows the Rebirth fanfare once it finishes, rather than
-- overlapping it (see economy.prestige). Edge-triggered on the fanfare
-- ending rather than tied to the modal, since the modal only re-arms via
-- demo_kind on the very first Rebirth (seen_modals carries the kind across
-- loops after that).
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
  -- First-wall teach: fire once the first time a Rebirth becomes affordable -
  -- the player has unlocked every track they can this loop, so the exit is the
  -- next step. Held behind any other modal so it doesn't stomp them.
  -- seen_modals.first_wall keeps it one-time.
  if not State.seen_modals.first_wall and not State.purchase_modal
      and not State.race_modal and not State.rebirth_confirm and not State.first_wall then
    if economy.rebirth_affordable() then
      State.first_wall = true
    end
  end
  if State.first_wall and input.pressed(input.BTN1) then
    State.first_wall             = nil
    State.seen_modals.first_wall = true
    persist.save()
  end
  -- BTN1 backs out of the Rebirth confirm rather than accepting it: the safe
  -- answer is the default for an irreversible choice, so a stray press can't
  -- wipe the loop. YES needs its own click (draw_rebirth_confirm).
  if State.rebirth_confirm and input.pressed(input.BTN1) then
    State.rebirth_confirm = nil
  end
  -- Loop timed out: once the clock hits zero and nothing else is on screen,
  -- raise the TIME'S UP breakdown. Held behind other modals so a just-finished
  -- race's result modal shows first. Detecting here (not just on enter) covers
  -- all arrival paths: idling on buy, returning from a timed-out race, and
  -- loading into buy with a dead clock. State.loop_timeout gates the modal; the
  -- reset happens on its dismissal, not here.
  if not State.loop_timeout and State.loop_time_left <= 0
      and not State.purchase_modal and not State.race_modal
      and not State.first_wall and not State.rebirth_confirm then
    State.loop_timeout = true
  end
  if State.loop_timeout and input.pressed(input.BTN1) then
    dismiss_timeout()
  end
  if not State.purchase_modal and not State.race_modal and not State.first_wall
      and not State.rebirth_confirm and not State.loop_timeout
      and input.key_pressed(input.KEY_SPACE) then
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
    -- Nothing in the data is free; kept for a base_cost of 0 during tuning.
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

-- The buy-next-track row: the climb within a loop. Shown on the top owned
-- track's page (the only page whose next corridor track is unowned). Priced at
-- the track's authored unlock_cost; buying it (economy.try_unlock_track) opens
-- it to race.
local function new_track_row(next_id, next_track_idx, x, y, w)
  local label = string.format("Track #%d", next_track_idx)
  local _, th = usagi.measure_text(label)
  local bh    = th * 2 + 4
  ui.label(label, x, y + math.floor((bh - th * 2) / 2))

  local cost       = track_data.unlock_cost(next_id)
  local affordable = State.money >= cost
  local cost_text  = "$" .. tostring(cost)
  local cost_color = affordable and gfx.COLOR_GREEN or gfx.COLOR_LIGHT_GRAY
  local bx         = x + w - SHOP_COST_W
  local btn_opts   = { w = SHOP_COST_W, disabled = not affordable, text = cost_color, dim_text = cost_color }
  local clicked    = ui.button(cost_text, bx, y, btn_opts)
  return clicked, bh
end

-- The Rebirth row: the loop-ender that stays in Samsara and climbs again,
-- priced at the top owned track's authored exit cost (economy.rebirth_cost).
-- Shows the ¥ this loop's race ranks have banked as the payoff (Q12c) - that's
-- what carries into the garage on reset. Renders only on the top owned track
-- (see draw_shop); disabled until the fare is affordable.
local function rebirth_row(x, y, w)
  local banked = economy.loop_yen_total()
  local label  = banked > 0 and string.format("Rebirth", banked) or "Rebirth"
  local _, th  = usagi.measure_text(label)
  local bh     = th * 2 + 4
  ui.label(label, x, y + math.floor((bh - th * 2) / 2), { color = gfx.COLOR_PINK })

  local cost       = economy.rebirth_cost()
  local affordable = State.money >= cost
  local cost_text  = "$" .. tostring(cost)
  local cost_color = affordable and gfx.COLOR_GREEN or gfx.COLOR_LIGHT_GRAY
  local bx         = x + w - SHOP_COST_W
  local btn_opts   = { w = SHOP_COST_W, disabled = not affordable, text = cost_color, dim_text = cost_color }
  local clicked    = ui.button(cost_text, bx, y, btn_opts)
  return clicked, bh
end

-- The Nirvana row: escape the loop - the eventual win, paired directly below
-- Rebirth on the top track as the other fork (stay in Samsara vs escape).
-- Fixed $300M price, button trimmed to "$300m", affordability-gated like any other
-- button. Non-functional for now (unreachable price, click is a no-op).
local function nirvana_row(x, y, w)
  local label = "Nirvana"
  local _, th = usagi.measure_text(label)
  local bh    = th * 2 + 4
  ui.label(label, x, y + math.floor((bh - th * 2) / 2), { color = gfx.COLOR_YELLOW })

  local affordable = State.money >= track_data.NIRVANA_COST
  local cost_color = affordable and gfx.COLOR_GREEN or gfx.COLOR_LIGHT_GRAY
  local bx         = x + w - SHOP_COST_W
  local btn_opts   = { w = SHOP_COST_W, disabled = not affordable, text = cost_color, dim_text = cost_color }
  local clicked    = ui.button("$300m", bx, y, btn_opts)
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
  if State.race_modal then
    M.draw_race_modal()
  elseif State.loop_timeout then
    M.draw_timeout()
  elseif State.first_wall then
    M.draw_first_wall()
  elseif State.rebirth_confirm then
    M.draw_rebirth_confirm()
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

-- Aligned character width of a "Label ..... VALUE" breakdown row, so the value
-- column right-aligns across the per-track and Loop Time lines.
local BREAKDOWN_ROW_CHARS = 20

-- Glyph count of a string. `#` counts bytes, which overcounts the multibyte ¥
-- in the reward row and would shift its value column out of line with the
-- rest; UTF-8 continuation bytes (0x80-0xBF) are what to skip.
local function glyph_len(s)
  local _, n = s:gsub("[^\128-\191]", "")
  return n
end

-- One dotted "Label ..... value" line padded to BREAKDOWN_ROW_CHARS.
local function breakdown_dots(label, value)
  local ndots = BREAKDOWN_ROW_CHARS - glyph_len(label) - glyph_len(value) - 2
  if ndots < 1 then ndots = 1 end
  return label .. " " .. string.rep(".", ndots) .. " " .. value
end

-- Draws one breakdown row centered at `cx`. Rows with a `rank` draw their
-- trailing rank letter in that rank's color (rank_color for the list, the
-- animated rank_text for the big `big` RANK line); the rest is light gray.
local function draw_breakdown_row(row, cx, y, scale)
  local text = row.text
  local w    = usagi.measure_text(text) * scale
  local x    = math.floor(cx - w / 2)
  if not row.rank then
    gfx.text_ex(text, x, y, scale, 0, gfx.COLOR_LIGHT_GRAY, 1)
    return
  end
  local prefix = text:sub(1, #text - #row.rank)
  local pw     = usagi.measure_text(prefix) * scale
  gfx.text_ex(prefix, x, y, scale, 0, gfx.COLOR_LIGHT_GRAY, 1)
  if row.big then
    ui.rank_text(row.rank, row.rank, x + pw, y, scale)
  else
    gfx.text_ex(row.rank, x + pw, y, scale, 0, ui.rank_color(row.rank, 0), 1)
  end
end

-- Rows of the Rebirth breakdown: a line per corridor track showing the ¥ its
-- best rank this loop is worth (with that rank colored), then the total. This
-- is the teacher of the whole climb - "race better, bank more ¥, upgrade more"
-- - shown live in the Rebirth confirm. A track not yet raced this loop reads as
-- a dash. The rank letter is the trailing token of the value ("¥60 A"), so
-- draw_breakdown_row colors it.
local function prestige_breakdown_rows()
  local rows    = {}
  local divider = string.rep("-", BREAKDOWN_ROW_CHARS)
  local total   = 0
  for _, id in ipairs(track_data.track_order()) do
    local ts    = State.tracks[id]
    local label = track_data.TRACKS[id].label
    local rank  = economy.track_rank(id)
    local yen   = economy.rank_yen(rank)
    if yen > 0 then
      if ts and ts.best_rate then
        total = total + yen
        rows[#rows + 1] = { text = breakdown_dots(label, "¥" .. yen .. " " .. rank), rank = rank }
      else
        rows[#rows + 1] = { text = breakdown_dots(label, "--") }
      end
    end
  end
  rows[#rows + 1] = { text = divider }
  rows[#rows + 1] = { text = breakdown_dots("Total ", "¥" .. total) }
  return rows
end

-- Packs breakdown `rows` for modal.draw: the plain-text body it measures the
-- panel from, plus the draw_body that paints the same rows with their rank
-- letters colored.
local function breakdown_body(rows)
  local lines = {}
  for _, r in ipairs(rows) do lines[#lines + 1] = r.text end
  local cx = math.floor(usagi.GAME_W / 2)
  return table.concat(lines, "\n"), function(_, by, scale)
    local _, line_h = usagi.measure_text("A")
    for _, r in ipairs(rows) do
      draw_breakdown_row(r, cx, by, scale)
      by = by + line_h * scale
    end
  end
end

-- Rebirth confirm: the ¥ breakdown live and before the fact. Rebirth wipes the
-- loop on the spot, so this is both the safety on an irreversible click and the
-- pitch: the player reads the ¥ each track's rank has banked toward the climb,
-- then decides whether one more run to raise a rank is worth more than resetting
-- now. The fare is already paid (the row's button is dead until affordable), so
-- the cost isn't restated - the live question is the ranks, not the price.
function M.draw_rebirth_confirm()
  local body, draw_body = breakdown_body(prestige_breakdown_rows())
  -- YES first, NOT YET second: BTN1 dismisses to NOT YET (see M.update), so
  -- the irreversible choice needs a deliberate click on its own button.
  local pressed         = modal.draw({
    title     = "Rebirth?",
    body      = body,
    draw_body = draw_body,
    buttons   = { "YES", "NOT YET" },
  })
  if pressed then
    State.rebirth_confirm = nil
    if pressed == 1 then economy.prestige() end
  end
end

-- Loop-timeout modal: the clock hit 0. Shows the same live ¥ breakdown as the
-- Rebirth confirm (read before the reset wipes State.tracks), under a rainbow
-- "TIME'S UP!" title with a single OKAY. It *replaces* the SAMSARA fanfare on
-- this path; dismissal fires the forced Rebirth and drops to the garage. A
-- BTN1 press dismisses in M.update.
function M.draw_timeout()
  local body, draw_body = breakdown_body(prestige_breakdown_rows())
  local draw_title      = function(x, y, scale) ui.rank_text("TIME'S UP!", "S", x, y, scale) end
  if modal.draw({
        title      = "TIME'S UP!",
        body       = body,
        draw_body  = draw_body,
        draw_title = draw_title,
        button     = "OKAY",
      }) then
    dismiss_timeout()
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

  -- Rebirth fires from the loop's ceiling track; the announcement names it
  -- plainly and the player navigates there with the `>` arrow once it's bought.
  if info.show_rebirth then
    body_parts[#body_parts + 1] = "Rebirth available - reset to grow stronger!"
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

-- First-wall teach modal (see FIRST_WALL_*). A button click dismisses here; a
-- BTN1 press dismisses in M.update. Both set seen_modals.first_wall so it never
-- shows again.
function M.draw_first_wall()
  if modal.draw({ title = FIRST_WALL_TITLE, body = FIRST_WALL_BODY }) then
    State.first_wall             = nil
    State.seen_modals.first_wall = true
    persist.save()
  end
end

function M.draw_shop()
  local x       = 8
  local w       = 200
  local gap     = 6

  local id      = State.active_track
  local idx     = track_data.get_track_index(id)
  local order   = track_data.track_order()
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
  for _, item in ipairs(track_data.shop(id)) do
    -- Checkpoint Pass (skill tree) grants every checkpoint outright, so
    -- there's nothing left for this row to sell. Coins don't exist at all
    -- until Loose Change is bought, and ghosts until Ghost Racer is bought,
    -- so those rows stay hidden rather than teasing a purchase - the node is
    -- the reveal.
    if not (item.kind == "checkpoints" and State.unlock_checkpoints)
        and not (item.kind == "coins" and not State.coins_unlocked)
        and not (item.kind == "ghosts" and not State.ghosts_unlocked) then
      local clicked, bh = shop_button(item, x, shop_y, w)
      if clicked then economy.try_buy(item.kind) end
      shop_y = shop_y + bh + gap
    end
  end

  -- The climb: the buy-next-track row sits on the top owned track's page (the
  -- only page whose next corridor track is unowned), offering to climb one more
  -- track this loop while the corridor has a next track left to buy.
  if id == economy.top_owned_track() then
    local next_track = economy.next_locked_track()
    if next_track and next_track == order[idx + 1] then
      local nt_clicked, nt_bh = new_track_row(next_track, idx + 1, x, shop_y, w)
      if nt_clicked and economy.try_unlock_track(next_track) then
        State.active_track = next_track
      end
      shop_y = shop_y + nt_bh + gap
    end
  end

  -- The loop-enders live on the top owned track (economy.rebirth_track), the
  -- fork paired with the climb: buy the next track to go higher, or end the loop
  -- from as far up as you've reached. Rebirth stays in Samsara and resets;
  -- Nirvana escapes the loop (the eventual win, non-functional for now).
  if id == economy.rebirth_track() then
    -- Rebirth routes through a confirm since it wipes the loop on the spot.
    local rb_clicked, rb_bh = rebirth_row(x, shop_y, w)
    if rb_clicked and economy.rebirth_affordable() then
      State.rebirth_confirm = true
    end
    shop_y = shop_y + rb_bh + gap

    local nv_clicked, nv_bh = nirvana_row(x, shop_y, w)
    if nv_clicked then economy.buy_nirvana() end
    shop_y = shop_y + nv_bh + gap
  end

  -- Global car-upgrades column, mirrored on the right edge. Wider cost
  -- buttons than the track shop so 5-digit prices fit.
  local uw     = 230
  local ux     = usagi.GAME_W - uw - 20
  local header = "Car Upgrades"
  local hw     = usagi.measure_text(header) * 2
  gfx.text_ex(header, ux + math.floor((uw - hw) / 2), nav_y + 10, 2, 0, gfx.COLOR_WHITE, 1)
  local uy = nav_y + th_a * 2 + 16
  for _, item in ipairs(track_data.upgrades()) do
    -- The magnet only pulls in coins, so it hides until the Loose Change skill
    -- node puts coins on sale (State.coins_unlocked). Launch Control (skill tree)
    -- starts every loop at max acceleration, so there's nothing left for that row.
    if not (item.kind == "magnet" and not State.coins_unlocked)
        and not (item.kind == "accel" and State.max_accel) then
      local clicked, bh = shop_button(item, ux, uy, uw, { cost_w = 70 })
      if clicked then economy.try_buy(item.kind) end
      uy = uy + bh + gap
    end
  end

  local race_x = math.floor((usagi.GAME_W - w) / 2)
  if ui.button("RACE", race_x, usagi.GAME_H - 60, { w = w, scale = 3 }) then
    SceneGoto("race")
  end
end

return M
