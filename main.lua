local persist    = require "persist"
local reference  = require "reference"
local buy        = require "scenes.buy"
local race       = require "scenes.race"
local intro      = require "scenes.intro"
local skill_tree = require "scenes.skill_tree"

local scenes     = { buy = buy, race = race, intro = intro, skill_tree = skill_tree }

-- Dev scenario to boot into instead of the real save: "loop2" or "loop3" (see
-- persist's DEV_SCENARIOS), nil for normal play. Each stands where that loop's
-- Rebirth drops the player - loop 2 on the title screen for its opening beats,
-- loop 3 in the first garage with loop 2's ¥ unspent. Applied only in dev
-- builds, and it overwrites the save file, so clear it once the run is over.
DEV_SCENARIO     = nil

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
    if DEV_SCENARIO then persist.dev_start_scenario(DEV_SCENARIO) end
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

-- Progression only saves on discrete events (buys, race enter/finish), but
-- ghost idle income accrues continuously (economy.bank in the scene updates),
-- so a periodic save keeps the running balance at most one period stale on
-- reload.
local AUTOSAVE_PERIOD = 5
local autosave_left   = AUTOSAVE_PERIOD

-- The loop clock bleeds only during active play: the buy screen and a live
-- race, and not while a blocking modal covers the shop or the first-race
-- controls screen is up. Pause is handled for free -- _update is skipped while
-- the engine pause overlay is open (USAGI.md).
local function clock_ticking()
  if State.mode == "buy" then
    return not (State.purchase_modal or State.race_modal or State.loop_timeout
      or buy.shop_modal_open())
  elseif State.mode == "race" then
    local r = State.race
    return r ~= nil and r.phase ~= "help"
  end
  return false -- skill_tree (garage) + intro never tick
end

function _update(dt)
  autosave_left = autosave_left - dt
  if autosave_left <= 0 then
    autosave_left = AUTOSAVE_PERIOD
    persist.save()
  end
  if clock_ticking() then
    State.loop_time_left = math.max(0, State.loop_time_left - dt)
  end
  scenes[State.mode].update(dt)
end

function _draw()
  gfx.shader_uniform("u_time", usagi.elapsed)
  gfx.shader_uniform("u_resolution", { usagi.GAME_W, usagi.GAME_H })
  scenes[State.mode].draw()
end
