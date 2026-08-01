-- Standalone harness for the loop-progression graph. Run with
-- `usagi dev loop_history_dev.lua`. No persistence, no game state - just
-- loop_history.draw fed synthetic histories.
--
-- The datasets are ending $/sec, which is what the history stores; the graph
-- plots the wait for $300m they imply. They're the shapes the real thing has to
-- survive, worst case first: the rate compounds across a run, so the wait
-- collapses across several orders of magnitude and the late loops are the ones
-- at risk of being flattened into the axis. Press L to swap the value axis to
-- linear and watch exactly that happen - that comparison is why it's log.
--
-- Dev keys: LEFT/RIGHT (or N) cycle datasets, L toggles log/linear,
-- M previews the graph inside the real loop-end modal, R resets.

local loop_history = require "loop_history"
local modal        = require "modal"

-- Each: { name, note, rates } - rates[i] is the ending $/sec of loop i.
local DATASETS     = {
  {
    name  = "typical run",
    note  = "compounding climb, loop 1 at zero",
    -- Loop 1 always ends at 0: ghosts arrive at loop 2. Every real history
    -- starts with that zero, so it's the default case, not an edge case.
    rates = { 0, 0.42, 1.8, 7.5, 26, 140, 900, 6200, 41000 },
  },
  {
    name  = "wild spread",
    note  = "$0 -> $2.4m/sec; the case log scale exists for",
    rates = { 0, 0.35, 4.1, 63, 1750, 48000, 2400000 },
  },
  {
    name  = "two points",
    note  = "the minimum the modal will show",
    rates = { 0, 0.61 },
  },
  {
    name  = "two points, both live",
    note  = "no zero row, tight range -> min-span floor kicks in",
    rates = { 118, 141 },
  },
  {
    name  = "plateau",
    note  = "stalled run; should look flat, not dramatic",
    rates = { 4200, 4310, 4180, 4400, 4290, 4350 },
  },
  {
    name  = "regression",
    note  = "a loop that went backwards mid-climb",
    rates = { 0, 1.2, 14, 190, 62, 240, 3100 },
  },
  {
    name  = "long run",
    note  = "24 loops; x-label thinning + point density",
    rates = (function()
      local r = { 0 }
      local v = 0.3
      for i = 2, 24 do
        -- Uneven growth so the line has some texture instead of a clean ramp.
        v = v * (1.9 + 0.9 * math.sin(i * 2.1))
        r[i] = v
      end
      return r
    end)(),
  },
  {
    name  = "all zeroes",
    note  = "degenerate: every loop is a 'never', nothing to plot",
    rates = { 0, 0, 0 },
  },
}

local function history_of(rates)
  local hist = loop_history.new()
  for i, rate in ipairs(rates) do
    loop_history.record(hist, i, rate)
  end
  return hist
end

function _config()
  return {
    name        = "Loop History Dev",
    game_width  = 640,
    game_height = 352,
  }
end

local function reset()
  State = {
    index  = 1,
    linear = false,
    modal  = false,
  }
end

function _init()
  reset()
  gfx.shader_set("vhs")
end

local function cycle(delta)
  State.index = (State.index - 1 + delta) % #DATASETS + 1
end

function _update(_dt)
  if input.key_pressed(input.KEY_R) then reset() end
  if input.key_pressed(input.KEY_RIGHT) or input.key_pressed(input.KEY_N) then cycle(1) end
  if input.key_pressed(input.KEY_LEFT) then cycle(-1) end
  if input.key_pressed(input.KEY_L) then State.linear = not State.linear end
  if input.key_pressed(input.KEY_M) then State.modal = not State.modal end
end

function _draw()
  gfx.shader_uniform("u_time", usagi.elapsed)
  gfx.shader_uniform("u_resolution", { usagi.GAME_W, usagi.GAME_H })
  gfx.clear(gfx.COLOR_DARK_BLUE)

  local set  = DATASETS[State.index]
  local hist = history_of(set.rates)
  local opts = { scale = State.linear and "linear" or "log" }

  gfx.text(string.format("[%d/%d] %s", State.index, #DATASETS, set.name), 8, 8, gfx.COLOR_WHITE)
  gfx.text(set.note, 8, 20, gfx.COLOR_LIGHT_GRAY)
  gfx.text(State.linear and "scale: LINEAR" or "scale: log",
    8, 32, State.linear and gfx.COLOR_RED or gfx.COLOR_LIGHT_GRAY)

  if State.modal then
    -- The shipping case: same call the loop-end modal makes, in the real
    -- panel, so the graph is checked at the size it actually appears.
    modal.draw({
      title = "THE CLIMB",
      body  = "How long $300m would take?",
      demo  = {
        w    = loop_history.GRAPH_W,
        h    = loop_history.GRAPH_H,
        draw = function(x, y)
          loop_history.draw(hist, x, y, loop_history.GRAPH_W, loop_history.GRAPH_H, opts)
        end,
      },
    })
  else
    -- Bare, and oversized: pixel-level check of the axis, gridlines, and
    -- label placement before they're shrunk into the modal.
    loop_history.draw(hist, 24, 56, 480, 200, opts)

    -- Same data at the size it ships at, side by side with the big one, so a
    -- label that only collides in the modal is visible here too.
    loop_history.draw(hist, 524, 56, 108, 200, opts)

    -- Both numbers per loop: the stored rate and the wait it plots as, so a
    -- point that looks wrong on the axis can be checked against its source.
    local y = 268
    for i, e in ipairs(hist) do
      if i <= 12 then
        gfx.text(string.format("L%d %s -> %s", e.loop, loop_history.rate_text(e.rate),
            loop_history.short_duration(loop_history.eta_of(e.rate))),
          24 + ((i - 1) % 4) * 150, y + math.floor((i - 1) / 4) * 12,
          gfx.COLOR_LIGHT_GRAY)
      end
    end
  end

  gfx.text("<- -> dataset   L log/linear   M modal preview   R reset",
    8, usagi.GAME_H - 12, gfx.COLOR_DARK_GRAY)
end
