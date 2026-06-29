local track_data             = require "track_data"

local tile_size              = track_data.tile_size

local tile_colors            = {
  [0] = gfx.COLOR_DARK_BLUE,
  [1] = gfx.COLOR_INDIGO,
  [2] = gfx.COLOR_BLACK,
  [3] = gfx.COLOR_WHITE,
}

local CHECKPOINT_LABEL_SCALE = 2
local GHOST_ALPHA            = 0.6

local M                      = {}

local function get_tile(map, x, y)
  local layer = map.layers[1].data
  local mw    = map.width
  local mh    = map.height
  local col   = math.floor(x / tile_size)
  local row   = math.floor(y / tile_size)
  if col < 0 or col >= mw or row < 0 or row >= mh then return 0 end
  return layer[row * mw + col + 1]
end

local function is_drivable(tile)
  return tile == 1 or tile == 3
end

function M.on_road(map, x, y, size, margin)
  local inner = size - margin - 1
  return is_drivable(get_tile(map, x + margin, y + margin))
      and is_drivable(get_tile(map, x + inner, y + margin))
      and is_drivable(get_tile(map, x + margin, y + inner))
      and is_drivable(get_tile(map, x + inner, y + inner))
end

function M.draw_track(map)
  local layer = map.layers[1].data
  local mw    = map.width
  local mh    = map.height
  for row = 0, mh - 1 do
    for col = 0, mw - 1 do
      local tile = layer[row * mw + col + 1]
      gfx.rect_fill(col * tile_size, row * tile_size, tile_size, tile_size,
        tile_colors[tile] or gfx.COLOR_INDIGO)
    end
  end
end

function M.draw_checkpoint(cp, n, faded)
  local rect          = track_data.checkpoint_rect(cp)
  local outline_color = gfx.COLOR_DARK_GREEN
  if not faded then
    outline_color = gfx.COLOR_DARK_GRAY
    gfx.rect_fill(rect.x, rect.y, rect.w, rect.h, gfx.COLOR_DARK_GREEN)
  end
  gfx.rect(rect.x, rect.y, rect.w, rect.h, outline_color)

  local label  = tostring(n)
  local tw, th = usagi.measure_text(label)
  local tx     = math.floor(rect.x + (rect.w - tw * CHECKPOINT_LABEL_SCALE) / 2)
  local ty     = math.floor(rect.y + (rect.h - th * CHECKPOINT_LABEL_SCALE) / 2)
  gfx.text_ex(label, tx, ty, CHECKPOINT_LABEL_SCALE, 0, gfx.COLOR_BLACK, faded and GHOST_ALPHA or 1)
end

function M.active_coin_count(unlocked, coins)
  return math.min(unlocked, #coins)
end

local COIN_SPRITE  = 4
local COIN_BOB_AMP = 0.6
local COIN_BOB_HZ  = 1.5

function M.draw_coins(coins, unlocked, collected)
  local bob = math.sin(usagi.elapsed * COIN_BOB_HZ * 2 * math.pi) * COIN_BOB_AMP
  for ci = 1, M.active_coin_count(unlocked, coins) do
    if not (collected and collected[ci]) then
      local coin = coins[ci]
      gfx.spr(COIN_SPRITE, coin.col * tile_size, coin.row * tile_size + bob)
    end
  end
end

return M
