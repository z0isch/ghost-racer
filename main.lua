local persist = require "persist"
local car     = require "car"
local ghost   = require "ghost"
local buy     = require "scenes.buy"
local race    = require "scenes.race"

local scenes  = { buy = buy, race = race }

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
  car.apply_upgrades(State.accel, State.top_speed)
  for id, _ in pairs(State.unlocked) do
    ghost.rebuild_sim(id)
  end
  -- enter initial scene without triggering exit on a previous scene
  scenes[State.mode].enter()
end

function _update(dt)
  scenes[State.mode].update(dt)
end

function _draw()
  scenes[State.mode].draw()
end
