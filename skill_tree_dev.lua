-- Standalone harness for the skill tree prototype. Run with
-- `usagi dev skill_tree_dev.lua`. Fresh state each run (no persistence).
-- Dev keys: R reset, = +100 SP, - -100 SP, L +1 loop (feeds the stats table
-- that node `locked` gates read). Each frame it runs apply_all on a fresh
-- ctx and dumps it, proving the callbacks fire (and stay idempotent).

local tree = require "skill_tree"

function _config()
  return {
    name        = "Skill Tree Dev",
    game_width  = 640,
    game_height = 352,
  }
end

function _init()
  State = {
    tree  = tree.new({ points = 500 }),
    stats = { loops = 0 },
  }
  gfx.shader_set("vhs")
end

function _update(_dt)
  if input.key_pressed(input.KEY_R) then
    State.tree  = tree.new({ points = 500 })
    State.stats = { loops = 0 }
  end
  if input.key_pressed(input.KEY_EQUAL) then
    State.tree.points = State.tree.points + 100
  end
  if input.key_pressed(input.KEY_MINUS) then
    State.tree.points = math.max(0, State.tree.points - 100)
  end
  if input.key_pressed(input.KEY_L) then
    State.stats.loops = State.stats.loops + 1
  end
end

function _draw()
  gfx.shader_uniform("u_time", usagi.elapsed)
  gfx.shader_uniform("u_resolution", { usagi.GAME_W, usagi.GAME_H })
  gfx.clear(gfx.COLOR_DARK_BLUE)
  tree.draw(State.tree, State.stats)

  -- Prove the apply() contract: run every owned callback into a fresh ctx
  -- and dump it. This is the harness stand-in for the real game consuming
  -- the tree. Keys are sorted so the dump doesn't flicker between orderings.
  local ctx  = tree.apply_all(State.tree, {})
  local keys = {}
  for k in pairs(ctx) do keys[#keys + 1] = k end
  table.sort(keys)

  local y = usagi.GAME_H - 60
  gfx.text("apply_all ctx:", 8, y, gfx.COLOR_LIGHT_GRAY)
  for _, k in ipairs(keys) do
    y = y + 12
    gfx.text("  " .. k .. " = " .. tostring(ctx[k]), 8, y, gfx.COLOR_WHITE)
  end
  gfx.text("R reset   = +100 SP   - -100 SP   L +1 loop (loops: "
    .. State.stats.loops .. ")", 8, usagi.GAME_H - 12, gfx.COLOR_DARK_GRAY)
end
