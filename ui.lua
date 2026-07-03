-- Immediate-mode UI helpers. Call from _draw.
-- ui.button returns true the frame a click completes (press + release on same button).
-- ui.label draws scaled/colored text at (x, y).
-- ui.rank_text draws text in the animated per-rank style (wave + color).
-- ui.coin_text draws text with every © in yellow.

local PAD_X = 4
local PAD_Y = 2
local DEFAULT_SCALE = 2

-- Wave amplitude (px at text scale AMP_SCALE, scales with the text) and text
-- color per rank; higher ranks bounce harder.
local AMP_SCALE = 3
local RANK_STYLE = {
  D = { color = gfx.COLOR_RED, amp = 0 },
  C = { color = gfx.COLOR_PEACH, amp = 1 },
  B = { color = gfx.COLOR_BLUE, amp = 2 },
  A = { color = gfx.COLOR_GREEN, amp = 3 },
  S = { rainbow = true, amp = 4 },
}

local RAINBOW = {
  gfx.COLOR_RED, gfx.COLOR_ORANGE, gfx.COLOR_YELLOW,
  gfx.COLOR_GREEN, gfx.COLOR_BLUE, gfx.COLOR_PINK,
}

local WAVE_SPEED = 7     -- rad/sec
local WAVE_PHASE = 0.8   -- rad offset per character
local RAINBOW_SPEED = 10 -- palette steps/sec

local active = nil       -- id of currently armed button (cleared on mouse release)

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

-- Draws `text` in the animated style of `rank`: per-character sine wave with
-- amplitude rising by rank, rank color (rainbow cycle for S). Returns the
-- drawn width so callers can lay out mixed-style lines.
function M.rank_text(text, rank, x, y, scale)
  local style = RANK_STYLE[rank]
  local amp   = style.amp * scale / AMP_SCALE
  local w     = 0
  for i = 1, #text do
    local ch    = text:sub(i, i)
    local wave  = math.sin(usagi.elapsed * WAVE_SPEED + i * WAVE_PHASE) * amp
    local color = style.color
    if style.rainbow then
      color = RAINBOW[(i + math.floor(usagi.elapsed * RAINBOW_SPEED)) % #RAINBOW + 1]
    end
    gfx.text_ex(ch, x + w, y + wave, scale, 0, color, 1)
    w = w + usagi.measure_text(ch) * scale
  end
  return w
end

-- Draws `text` at (x, y) in `color`, with every © drawn in yellow. Returns
-- the drawn width so callers can lay out mixed-style lines.
function M.coin_text(text, x, y, scale, color, alpha)
  alpha = alpha or 1
  local w = 0
  local i = 1
  while i <= #text do
    local s, e = text:find("©", i, true)
    local chunk, chunk_color
    if s == i then
      chunk, chunk_color = "©", gfx.COLOR_YELLOW
      i = e + 1
    else
      chunk, chunk_color = text:sub(i, s and s - 1 or #text), color
      i = s or #text + 1
    end
    gfx.text_ex(chunk, x + w, y, scale, 0, chunk_color, alpha)
    w = w + usagi.measure_text(chunk) * scale
  end
  return w
end

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
  opts           = opts or {}
  local scale    = opts.scale or DEFAULT_SCALE
  local tw, th   = usagi.measure_text(label)
  local bw       = opts.w or (tw * scale + PAD_X * 2)
  local bh       = th * scale + PAD_Y * 2
  local rect     = { x = x, y = y, w = bw, h = bh }
  local id       = x .. "," .. y
  local disabled = opts.disabled or false

  local mx, my   = input.mouse()
  local mouse    = { x = mx, y = my }
  local in_win   = mx >= 0 and mx < usagi.GAME_W and my >= 0 and my < usagi.GAME_H
  local hovered  = in_win and util.point_in_rect(mouse, rect) and not disabled

  local clicked  = false
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
    fill         = opts.dim or M.theme.dim
    border_color = opts.dim or M.theme.dim
    text_color   = opts.dim_text or M.theme.dim_text
  elseif active == id and hovered then
    fill         = opts.pressed or M.theme.pressed
    border_color = opts.border or M.theme.border
    text_color   = opts.text or M.theme.text
  elseif hovered then
    fill         = opts.hover or M.theme.hover
    border_color = opts.border or M.theme.border
    text_color   = opts.text or M.theme.text
  else
    fill         = opts.fill or M.theme.fill
    border_color = opts.border or M.theme.border
    text_color   = opts.text or M.theme.text
  end

  gfx.rect_fill(x, y, bw, bh, fill)
  gfx.rect(x, y, bw, bh, border_color)

  local tx = x + math.floor((bw - tw * scale) / 2)
  local ty = y + math.floor((bh - th * scale) / 2)
  gfx.text_ex(label, tx, ty, scale, 0, text_color, 1.0)

  return clicked
end

return M
