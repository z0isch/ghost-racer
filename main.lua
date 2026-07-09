local persist = require "persist"
local buy     = require "scenes.buy"
local race    = require "scenes.race"
local intro   = require "scenes.intro"

local scenes  = { buy = buy, race = race, intro = intro }

function SceneGoto(mode)
  local prev = State.mode
  State.mode = mode
  if scenes[prev] then scenes[prev].exit() end
  if scenes[mode] then scenes[mode].enter() end
end

function _config()
  return {
    name        = "Usagi Test",
    game_id     = "com.usagi.drift",
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
  end
  --persist.start_new_loop()
  -- enter initial scene without triggering exit on a previous scene
  scenes[State.mode].enter()
end

function _update(dt)
  State.loop_time = (State.loop_time or 0) + dt
  scenes[State.mode].update(dt)
end

function _draw()
  scenes[State.mode].draw()
end
