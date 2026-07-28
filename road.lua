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

function M.draw_checkpoint(cp, n, faded, total)
  local rect          = track_data.checkpoint_rect(cp)
  local outline_color = gfx.COLOR_DARK_GREEN
  if not faded then
    outline_color = gfx.COLOR_DARK_GRAY
    gfx.rect_fill(rect.x, rect.y, rect.w, rect.h, gfx.COLOR_DARK_GREEN)
  end
  gfx.rect(rect.x, rect.y, rect.w, rect.h, outline_color)

  if total and total <= 1 then return end

  local label  = tostring(n)
  local tw, th = usagi.measure_text(label)
  local tx     = math.floor(rect.x + (rect.w - tw * CHECKPOINT_LABEL_SCALE) / 2)
  local ty     = math.floor(rect.y + (rect.h - th * CHECKPOINT_LABEL_SCALE) / 2)
  gfx.text_ex(label, tx, ty, CHECKPOINT_LABEL_SCALE, 0, gfx.COLOR_BLACK,
    faded and GHOST_ALPHA or 1)
end

function M.active_coin_count(unlocked, coins)
  return math.min(unlocked, #coins)
end

local COIN_SPRITE  = 4
-- The lap-2 coin: the same coin art recolored to PICO-8 pink, which the
-- project palette maps to #ff5fd0. A literal purple would read as a hole in the
-- track - the road is already indigo #715f9e, and every darker purple in this
-- palette sits below it in brightness. Tinting can't get there either: spr_ex's
-- tint is a multiply and the coin's blue channel is 0x36, so any tint crushes
-- blue to nothing. Hence a second painted sprite rather than a tinted draw.
local COIN2_SPRITE = 5
local COIN_BOB_AMP = 0.6
local COIN_BOB_HZ  = 1.5

local function draw_coin_list(coins, unlocked, collected, sprite, bob, alpha)
  for ci = 1, M.active_coin_count(unlocked, coins) do
    if not (collected and collected[ci]) then
      local coin = coins[ci]
      gfx.spr(sprite, coin.col * tile_size, coin.row * tile_size + bob, alpha)
    end
  end
end

-- Draws both of a track's coin lists. `collected` is the race's per-list
-- collected sets ({ lap1, lap2 }), nil on the buy-screen preview; `lap` is the
-- race's current lap, nil for that same preview (which shows everything live).
function M.draw_coins(id, unlocked, collected, lap)
  local tdata = track_data.TRACKS[id]
  local bob   = math.sin(usagi.elapsed * COIN_BOB_HZ * 2 * math.pi) * COIN_BOB_AMP
  draw_coin_list(tdata.coins, unlocked, collected and collected[1], COIN_SPRITE, bob)

  if not tdata.coins2 or track_data.effective_laps(id) < 2 then return end
  -- Full alpha with the bob frozen while lap 1 is still running. The bob is
  -- this game's "alive and collectable" tell, and low alpha already means
  -- *inactive* everywhere else (open gates, ghosts) - so a still, opaque coin
  -- says "real, but not yet" without spending the contrast against the road.
  local live = lap == nil or lap > 1
  draw_coin_list(tdata.coins2, unlocked, collected and collected[2], COIN2_SPRITE,
    live and bob or 0, live and 1 or 0.3)
end

return M
