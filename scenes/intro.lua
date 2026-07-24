local ui           = require "ui"
local road         = require "road"
local track_data   = require "track_data"
local car          = require "car"
local modal        = require "modal"

local M            = {}

-- Opening story beats, shown in order once the player commits to their first
-- race by pressing RACE on the title screen (the intro scene only loads when
-- there's no save file - see persist.load). Each is one CONTINUE click;
-- dismissing the last drops into the race. Not persisted: autosave writes a
-- save within seconds of boot, so a reload lands in `buy` and the intro is
-- genuinely one-shot.
local INTRO_MODALS = {
  '"You want me to do what\nexactly now?"',
  '"300 million dollars,\n5 minutes"',
  '"That\'s impossible!\nA million dollars\nevery second?!"',
  '"You got this - Godspeed!"',
}

-- Index of the intro modal currently showing, or 0 while the title screen with
-- its RACE button is up (the sequence hasn't started). Advancing past the last
-- modal hands off to the race.
local modal_idx

-- Advances the intro dialogue one beat; past the last modal, starts the race.
local function advance_modal()
  modal_idx = modal_idx + 1
  if modal_idx > #INTRO_MODALS then
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
    if modal.draw({ title = "", body = INTRO_MODALS[modal_idx], button = "CONTINUE" }) then
      advance_modal()
    end
    return
  end

  local w      = 200
  local race_x = math.floor((usagi.GAME_W - w) / 2)
  if ui.button("RACE", race_x, usagi.GAME_H - 120, { w = w, scale = 3 }) then
    modal_idx = 1
  end
end

return M
