local persist     = require "persist"
local reference   = require "reference"
local buy         = require "scenes.buy"
local race        = require "scenes.race"
local intro       = require "scenes.intro"
local skill_tree  = require "scenes.skill_tree"

local scenes  = { buy = buy, race = race, intro = intro, skill_tree = skill_tree }

function SceneGoto(mode)
  local prev = State.mode
  State.mode = mode
  if scenes[prev] then scenes[prev].exit() end
  if scenes[mode] then scenes[mode].enter() end
end

function _config()
  return {
    name        = "Ghost Loop",
    game_id     = "com.usagi.ghost.loop",
    game_width  = 640,
    game_height = 352,
  }
end

function _init()
  persist.load()
  persist.resync_car_and_ghosts()

  if usagi.IS_DEV then
    usagi.menu_item("Dev: Save State", function()
      persist.dev_save_snapshot()
    end)
    usagi.menu_item("Dev: Load State", function()
      persist.dev_load_snapshot()
    end)
    -- Force the just-finished lap to become this track's reference line, even
    -- if it wasn't the fastest (finish a race first, then pick this from the
    -- garage). Auto-capture on finish already keeps the fastest full-course lap.
    usagi.menu_item("Dev: Save Reference Lap", function()
      if State.race and State.race.phase == "finished" then
        reference.force_capture(State.active_track, State.race.recording, State.race.time)
      else
        print("[ref] finish a lap first, then Save Reference Lap")
      end
    end)
  end
  --persist.start_new_loop()
  gfx.shader_set("vhs")
  -- enter initial scene without triggering exit on a previous scene
  scenes[State.mode].enter()
end

-- Progression only saves on discrete events (buys, race enter/finish), so
-- the ticking loop clock would rewind to the last event on reload. A
-- periodic save keeps it at most one period stale.
local AUTOSAVE_PERIOD = 5
local autosave_left   = AUTOSAVE_PERIOD

-- Scenes where the loop clock runs. The garage and title screens sit between
-- loops (start_new_loop zeroes loop_time), so time spent there doesn't count
-- against the new loop's rank.
local LOOP_CLOCK_MODES = { buy = true, race = true }

function _update(dt)
  if LOOP_CLOCK_MODES[State.mode] then
    State.loop_time = (State.loop_time or 0) + dt
  end
  autosave_left = autosave_left - dt
  if autosave_left <= 0 then
    autosave_left = AUTOSAVE_PERIOD
    persist.save()
  end
  scenes[State.mode].update(dt)
end

function _draw()
  gfx.shader_uniform("u_time", usagi.elapsed)
  gfx.shader_uniform("u_resolution", { usagi.GAME_W, usagi.GAME_H })
  scenes[State.mode].draw()
end
