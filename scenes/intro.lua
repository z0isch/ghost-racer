local ui           = require "ui"
local road         = require "road"
local track_data   = require "track_data"
local car          = require "car"
local modal        = require "modal"

local M            = {}

-- Story beats keyed by the loop they play on, shown in order once the player
-- commits to that loop's first race by pressing RACE on the title screen (on
-- boot the intro scene only loads when there's no save file - see persist.load
-- - but every loop returns here, from the garage's NEXT button or, for loop 2,
-- straight off the TIME'S UP modal). Each is one CONTINUE click; dismissing the
-- last drops into the race. A loop with no entry here races immediately - by
-- loop 3 the story is told. Not persisted: autosave writes a save within
-- seconds, so a reload lands in `buy` and that loop's beats are missed.
local LOOP_MODALS = {
  [1] = {
    '"You want me to do what\nexactly now?"',
    '"300 million dollars,\n5 minutes"',
    '"That\'s impossible!\nA million dollars\nevery second?!"',
    '"You got this - Godspeed!"',
  },
  -- Loop 2 opens on the same demand, word for word - the joke of the loop -
  -- then hands over ghosts and points at the shop row they now appear in.
  [2] = {
    '"300 million dollars,\n5 minutes"',
    '"Not again..."',
    '"It\'s okay, you can now enlist\nsome racers stuck in the same\nloop as you to help!\nCheck out the ghost option\nin the shop."',
  },
}

-- Index of the intro modal currently showing, or 0 while the title screen with
-- its RACE button is up (the sequence hasn't started). Advancing past the last
-- modal hands off to the race.
local modal_idx

-- Advances the dialogue one beat; past the last modal, starts the race.
local function advance_modal()
  local beats = LOOP_MODALS[State.loop]
  modal_idx   = modal_idx + 1
  if not beats or modal_idx > #beats then
    SceneGoto("race")
  end
end

function M.enter()
  -- Guarantees engine silence on every path in, including dev live-reload
  -- and Reset, which keep the music channel playing across _init.
  car.stop_engine(State.car)
  modal_idx = 0
end

function M.exit()
end

function M.update(dt)
  -- Keyboard dismiss, mirroring the mouse click handled in M.draw (buttons are
  -- mouse-only; see ui.button). Only live once the sequence has started.
  if modal_idx >= 1 and input.pressed(input.BTN1) then
    advance_modal()
  end
end

function M.draw()
  local title = "Ghost Loop"
  gfx.rect_fill(0, 0, usagi.GAME_W, usagi.GAME_H, gfx.COLOR_BLACK)
  local scale = 5
  local tw    = usagi.measure_text(title) * scale
  local _, th = usagi.measure_text(title)
  local tx    = math.floor((usagi.GAME_W - tw) / 2)
  local ty    = math.floor(usagi.GAME_H / 3 - th * scale / 2)

  ui.neon_text(title, tx, ty, scale, {
    shadow = gfx.COLOR_DARK_PURPLE,
    wave_amp = 10,
    wave_speed = 4,
    wave_phase = 0.5,
  })

  if State.loop >= 2 then
    local tag = "LOOP " .. State.loop
    local tw2 = usagi.measure_text(tag) * 2
    ui.neon_text(tag, math.floor((usagi.GAME_W - tw2) / 2), ty + th * scale + 12, 2, {
      colors = { gfx.COLOR_LIGHT_GRAY },
      shadow = gfx.COLOR_DARK_PURPLE,
    })
  end

  -- Once RACE is pressed, the opening dialogue runs over the title; dismissing
  -- the last beat starts the race (advance_modal).
  if modal_idx >= 1 then
    local beats = LOOP_MODALS[State.loop]
    if modal.draw({ title = "", body = beats[modal_idx], button = "CONTINUE" }) then
      advance_modal()
    end
    return
  end

  local w      = 200
  local race_x = math.floor((usagi.GAME_W - w) / 2)
  if ui.button("RACE", race_x, usagi.GAME_H - 120, { w = w, scale = 3 }) then
    if LOOP_MODALS[State.loop] then
      modal_idx = 1
    else
      SceneGoto("race")
    end
  end
end

return M
