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
local loop_history     = require "loop_history"

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
  laps = {
    title = "Extra Lap Unlocked!",
    body  = function()
      return
      "This track now runs twice.\nLap 2 pays double at every\ncheckpoint - and opens a\nsecond set of coins."
    end,
  },
}

-- First-ever shop visit: a one-shot explainer of what the race $ buys - car
-- upgrades and the next track - and that a better rank pays more, so racing
-- better is what funds the climb. Gated on State.seen_modals.shop, which
-- persists across loops (the ¥/garage counterpart lives in scenes/skill_tree).
local SHOP_MODAL_TITLE = "Welcome to the Shop!"
local SHOP_MODAL_BODY  = table.concat({
  "Spend the $ you earn racing on upgrades for your",
  "car and on new tracks to race.",
  "",
  "The better your rank, the more $ it pays every race.",
  "",
  "Don't worry, you can never lose rank once earned.",
}, "\n")

-- Clears the purchase modal.
local function dismiss_purchase_modal()
  State.purchase_modal = nil
end

-- Dismissing the shop explainer records it as seen for good.
local function dismiss_shop_modal()
  State.seen_modals.shop = true
  persist.save()
end

-- Scripted beats that open the TIME'S UP modal, keyed by the loop that just
-- ended: the taskmaster who set the $300M task in the intro answers the dead
-- clock, in the same voice. Each is one CONTINUE click, intro-style; after the
-- last, loops 2+ show the real ¥ breakdown. Loop 1 has no beats after its own:
-- it banks no ¥ (economy.bank_race_yen) and has no garage to spend it in, so
-- the breakdown would be a table of dashes and its taunt is the whole modal.
local TIMEOUT_BEATS = {
  [1] = {
    table.concat({
      '"Too bad, no $300 million."',
      "",
      '"That\'s okay - you\'re stuck in',
      'this loop until you make it."',
    }, "\n"),
  },
  -- Loop 2 ends on the same taunt, but this is the first Rebirth that lands in
  -- the garage, so the beats hand over the rule that makes it worth anything:
  -- race better -> higher rank -> more ¥ -> upgrades that outlive the loop.
  -- The taunt is a function (like MODAL_INFO's body) so it can quote how far
  -- off Nirvana the player's ghost income actually was, using the same ETA
  -- math and formatting the HUD's $300m readout uses (duration_text).
  [2] = {
    function()
      local lines = { '"Well that wasn\'t close.' }
      local secs  = economy.seconds_to_nirvana(economy.ghost_cash_rate())
      if secs then
        lines[#lines + 1] = ""
        lines[#lines + 1] = '"We don\'t have ' .. loop_history.duration_text(secs) .. ' to wait."'
      end
      return table.concat(lines, "\n")
    end,
    table.concat({
      '"Fine. A little more help."',
      "",
      '"You now earn ¥ that you can spend on upgrades.',
      'The better you race, the more ¥ you earn',
      'and upgrades persist accross loops.'
    }, "\n"),
  },
}

-- The timeout sequence, in order: this loop's beats, then the ¥ breakdown for
-- every loop that banks any (loop 1 doesn't), then the progression graph once
-- there's more than one loop's ending wait-for-$300m to plot. Each is one step of
-- State.loop_timeout; these say which step is which, so the draw doesn't have
-- to re-derive the layout from the index.
local function beat_count()
  local beats = TIMEOUT_BEATS[State.loop]
  return beats and #beats or 0
end

local function breakdown_step()
  return State.loop >= 2 and beat_count() + 1 or nil
end

-- Present only from the second recorded loop on: one dot isn't a progression.
-- The recording happens as the sequence opens (record_loop_end), so this is
-- stable for the whole sequence.
local function graph_step()
  if not loop_history.has_graph(State.loop_history) then return nil end
  return (breakdown_step() or beat_count()) + 1
end

local function timeout_steps()
  return graph_step() or breakdown_step() or beat_count()
end

-- Files this loop's ending ghost income before anything resets it, at the
-- moment the timeout sequence opens. Idempotent per loop (loop_history.record
-- upserts), so re-entering the sequence - quitting and reloading into a dead
-- clock - corrects the entry instead of doubling it.
local function record_loop_end()
  loop_history.record(State.loop_history, State.loop, economy.ghost_cash_rate())
  persist.save()
end

-- Dismissing the last TIME'S UP step fires the Rebirth, then routes on. The
-- clock is the only loop-ender - the player races until it runs out. Banked ¥
-- already lives in the skill tree (bank_race_yen), so only in-loop money and
-- track ownership reset.
local function dismiss_timeout()
  State.loop_timeout = nil
  persist.start_new_loop()
  -- start_new_loop already advanced the counter, so this reads the loop being
  -- entered. Loop 2 skips the garage: nothing was banked to spend, and its one
  -- new toy (ghosts) is handed over by the story, not bought - so it lands on
  -- the title screen for its opening beats instead. Every later loop rebirths
  -- into the garage as usual.
  SceneGoto(State.loop == 2 and "intro" or "skill_tree")
end

-- Advances the timeout sequence one step; past the last, fires the Rebirth.
local function advance_timeout()
  local step = State.loop_timeout + 1
  if step > timeout_steps() then
    dismiss_timeout()
  else
    State.loop_timeout = step
  end
end

local M = {}

-- Which kind the demo loop was last reset for, so it restarts per modal.
local demo_kind

-- True while the first-visit shop explainer is up. It blocks the shop
-- underneath, and pauses the loop clock (see main.lua clock_ticking) so the
-- read isn't on the player's dime.
function M.shop_modal_open()
  return not State.seen_modals.shop
end

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
  -- Checked before the dismissals below (which clear their flags in place) so
  -- the press that clears a just-finished race's result modal doesn't also blow
  -- past this one - it's held behind them, matching the draw order.
  if M.shop_modal_open() and not State.purchase_modal and not State.race_modal
      and not State.loop_timeout and input.pressed(input.BTN1) then
    dismiss_shop_modal()
  end
  if State.purchase_modal and input.pressed(input.BTN1) then
    dismiss_purchase_modal()
  end
  if State.race_modal and input.pressed(input.BTN1) then
    State.race_modal = nil
  end
  -- Loop timed out: once the clock hits zero and nothing else is on screen,
  -- raise the TIME'S UP breakdown. Held behind other modals so a just-finished
  -- race's result modal shows first. Detecting here (not just on enter) covers
  -- all arrival paths: idling on buy, returning from a timed-out race, and
  -- loading into buy with a dead clock. State.loop_timeout gates the modal and
  -- indexes its step (beats first, then the breakdown); the reset happens when
  -- the last step is dismissed, not here.
  if not State.loop_timeout and State.loop_time_left <= 0
      and not State.purchase_modal and not State.race_modal
      and not M.shop_modal_open() then
    record_loop_end()
    State.loop_timeout = 1
  end
  if State.loop_timeout and input.pressed(input.BTN1) then
    advance_timeout()
  end
  if not State.purchase_modal and not State.race_modal
      and not State.loop_timeout and not M.shop_modal_open()
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

-- The Nirvana row: escape the loop - the eventual win, and the only loop-ender
-- the player can buy (Rebirth isn't for sale; the clock ends every loop). Lives
-- on the top owned track, directly under the climb. Fixed $300M price, button
-- trimmed to "$300m", affordability-gated like any other button. Non-functional
-- for now (unreachable price, click is a no-op).
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
    road.draw_checkpoint(cp, i, true, #checkpoints)
  end
  road.draw_coins(id, State.tracks[id].coins, State.tracks[id].coins2)
  ghost.draw_sim(GHOST_ALPHA)
  popups.draw()
  hud.draw()
  if State.race_modal then
    M.draw_race_modal()
  elseif State.loop_timeout then
    M.draw_timeout()
  elseif State.purchase_modal then
    M.draw_purchase_modal()
  elseif M.shop_modal_open() then
    M.draw_shop_modal()
  else
    M.draw_shop()
  end
end

-- First-visit shop explainer, drawn instead of the shop (like the garage's)
-- so a dismiss click can't fall through onto a shop button. A BTN1 press
-- dismisses in M.update.
function M.draw_shop_modal()
  if modal.draw({ title = SHOP_MODAL_TITLE, body = SHOP_MODAL_BODY }) then
    dismiss_shop_modal()
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
-- animated rank_text for the big `big` RANK line); the rest is light gray with
-- currency glyphs yellow (coin_text), matching modal's default body render.
local function draw_breakdown_row(row, cx, y, scale)
  local text = row.text
  local w    = usagi.measure_text(text) * scale
  local x    = math.floor(cx - w / 2)
  if not row.rank then
    ui.coin_text(text, x, y, scale, gfx.COLOR_LIGHT_GRAY)
    return
  end
  local prefix = text:sub(1, #text - #row.rank)
  local pw     = usagi.measure_text(prefix) * scale
  ui.coin_text(prefix, x, y, scale, gfx.COLOR_LIGHT_GRAY)
  if row.big then
    ui.rank_text(row.rank, row.rank, x + pw, y, scale)
  else
    gfx.text_ex(row.rank, x + pw, y, scale, 0, ui.rank_color(row.rank, 0), 1)
  end
end

-- Rows of the loop breakdown: a line per corridor track showing the ¥ its
-- best rank this loop is worth (with that rank colored), then the total. This
-- is the teacher of the whole climb - "race better, bank more ¥, upgrade more"
-- - shown when the clock runs out. A track not yet raced this loop reads as
-- a dash. The rank letter is the trailing token of the value ("¥60 A"), so
-- draw_breakdown_row colors it.
local function loop_breakdown_rows()
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

-- Loop-timeout modal: the clock hit 0, which is the only way a loop ends. Runs
-- this loop's scripted beats (TIMEOUT_BEATS), then the ¥ breakdown (read before
-- the reset wipes State.tracks), then the progression graph - so loop 1 is
-- beat-only and loops 3+, with no beats left to play, are breakdown-then-graph.
-- The first step announces the dead clock under a rainbow "TIME'S UP!" title,
-- and the breakdown carries it again over its table; the beats between are
-- dialogue-only, like the intro's, and the graph titles itself.
-- Dismissing the last step fires the Rebirth and routes on. A BTN1 press
-- advances in M.update.
function M.draw_timeout()
  local step  = State.loop_timeout
  local beats = TIMEOUT_BEATS[State.loop]
  local last  = step == timeout_steps()

  -- The graph closes the sequence: the ¥ breakdown says what this one loop
  -- earned, and the graph puts that number next to every loop before it, which
  -- is the note to leave on before Rebirth wipes the climb.
  if step == graph_step() then
    local hist = State.loop_history
    if modal.draw({
          title  = "THE CLIMB",
          body   = "How long $300m would take?",
          demo   = {
            w    = loop_history.GRAPH_W,
            h    = loop_history.GRAPH_H,
            draw = function(x, y)
              loop_history.draw(hist, x, y, loop_history.GRAPH_W, loop_history.GRAPH_H)
            end,
          },
          button = last and "OKAY" or "CONTINUE",
        }) then
      advance_timeout()
    end
    return
  end

  local titled = step == 1 or (beats and step > #beats)

  local body, draw_body
  if beats and step <= #beats then
    local beat = beats[step]
    body       = type(beat) == "function" and beat() or beat
  else
    body, draw_body = breakdown_body(loop_breakdown_rows())
  end

  local draw_title
  if titled then
    draw_title = function(x, y, scale) ui.rank_text("TIME'S UP!", "S", x, y, scale) end
  end
  if modal.draw({
        title      = titled and "TIME'S UP!" or "",
        body       = body,
        draw_body  = draw_body,
        draw_title = draw_title,
        button     = last and "OKAY" or "CONTINUE",
      }) then
    advance_timeout()
  end
end

-- Post-race modal: shown after the very first lap on a track (explains the
-- beat-your-lap loop) and after any lap that raised the track's rank (shows the
-- pay-rate changes). Both can coincide on one lap; they share this single modal
-- rather than stacking separate popups. See scenes/race.lua finish_race().
function M.draw_race_modal()
  local info         = State.race_modal
  local id           = info.track_id
  local rank_changed = info.prev_rank ~= nil

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

  local body       = table.concat(body_parts, "\n\n")

  local title      = "RANK " .. info.rank .. (rank_changed and "!" or "")
  local draw_title = function(x, y, scale)
    local rx = x
    rx = rx + ui.coin_text("RANK ", rx, y, scale, gfx.COLOR_WHITE)
    rx = rx + ui.rank_text(info.rank, info.rank, rx, y, scale)
    if rank_changed then
      ui.coin_text("!", rx, y, scale, gfx.COLOR_WHITE)
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
    -- Coins don't exist at all until Loose Change is bought, and ghosts until
    -- loop 2 hands them over, so those rows stay hidden rather than teasing a
    -- purchase - their arrival is the reveal. Extra Lap needs both the node's
    -- purchase ceiling and the track's own laps ceiling. The lap-2 coins have
    -- no row of their own: the Coin row sells them once the gold set is gone
    -- and the lap is bought (see economy.next_coin_field).
    if not (item.kind == "coins" and not State.coins_unlocked)
        and not (item.kind == "ghosts" and not State.ghosts_unlocked)
        and not (item.kind == "laps" and not (State.laps > 1 and track_data.TRACKS[id].laps)) then
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

  -- Nirvana lives on the top owned track, under the climb: escaping the loop
  -- fires from as far up the corridor as the player reached. It's the only
  -- loop-ender for sale - Rebirth isn't bought, the clock brings it.
  if id == economy.top_owned_track() then
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
