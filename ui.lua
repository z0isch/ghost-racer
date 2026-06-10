-- Immediate-mode UI helpers. Call from _draw.
-- ui.button returns true the frame a click completes (press + release on same button).
-- ui.label draws scaled/colored text at (x, y).

local PAD_X = 12
local PAD_Y = 6
local DEFAULT_SCALE = 2

local active = nil  -- id of currently armed button (cleared on mouse release)

local M = {}

M.theme = {
  fill     = gfx.COLOR_DARK_GRAY,
  hover    = gfx.COLOR_INDIGO,
  pressed  = gfx.COLOR_DARK_BLUE,
  border   = gfx.COLOR_WHITE,
  text     = gfx.COLOR_WHITE,
  dim      = gfx.COLOR_DARK_GRAY,
  dim_text = gfx.COLOR_LIGHT_GRAY,
}

function M.label(text, x, y, opts)
  opts = opts or {}
  local scale = opts.scale or DEFAULT_SCALE
  local color = opts.color or M.theme.text
  local alpha = opts.alpha or 1.0
  gfx.text_ex(text, x, y, scale, 0, color, alpha)
end

-- Returns true the frame the button is clicked (released while hovered).
-- opts: w, scale, fill, hover, pressed, border, text, dim, dim_text,
--       disabled (bool), sfx (string)
function M.button(label, x, y, opts)
  opts = opts or {}
  local scale    = opts.scale or DEFAULT_SCALE
  local tw, th   = usagi.measure_text(label)
  local bw       = opts.w or (tw * scale + PAD_X * 2)
  local bh       = th * scale + PAD_Y * 2
  local rect     = { x = x, y = y, w = bw, h = bh }
  local id       = x .. "," .. y
  local disabled = opts.disabled or false

  local mx, my  = input.mouse()
  local mouse   = { x = mx, y = my }
  local in_win  = mx >= 0 and mx < usagi.GAME_W and my >= 0 and my < usagi.GAME_H
  local hovered = in_win and util.point_in_rect(mouse, rect) and not disabled

  local clicked = false
  if not disabled then
    if hovered and input.mouse_pressed(input.MOUSE_LEFT) then
      active = id
    end
    if input.mouse_released(input.MOUSE_LEFT) then
      if active == id and hovered then
        clicked = true
        if opts.sfx then sfx.play(opts.sfx) end
      end
      if active == id then active = nil end
    end
  end

  local fill, border_color, text_color
  if disabled then
    fill         = opts.dim      or M.theme.dim
    border_color = opts.dim      or M.theme.dim
    text_color   = opts.dim_text or M.theme.dim_text
  elseif active == id and hovered then
    fill         = opts.pressed  or M.theme.pressed
    border_color = opts.border   or M.theme.border
    text_color   = opts.text     or M.theme.text
  elseif hovered then
    fill         = opts.hover    or M.theme.hover
    border_color = opts.border   or M.theme.border
    text_color   = opts.text     or M.theme.text
  else
    fill         = opts.fill     or M.theme.fill
    border_color = opts.border   or M.theme.border
    text_color   = opts.text     or M.theme.text
  end

  gfx.rect_fill(x, y, bw, bh, fill)
  gfx.rect(x, y, bw, bh, border_color)

  local tx = x + math.floor((bw - tw * scale) / 2)
  local ty = y + math.floor((bh - th * scale) / 2)
  gfx.text_ex(label, tx, ty, scale, 0, text_color, 1.0)

  return clicked
end

return M
