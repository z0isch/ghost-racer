local track_data             = require "track_data"

local tile_size              = track_data.tile_size

-- Level colors, in two sets: the normal one and the one REVERSE_MODE swaps in,
-- so a mirrored level is recognizable as its own place rather than as track N
-- with the pixels flipped.
--
-- The reverse set re-hues rather than inverts: the violet/blue normal theme
-- becomes teal-on-black, the same darkness with a different temperature. A
-- literal photo-negative was the first cut and read far too bright -- it landed
-- at avg luminance 165 against normal's 93, because inverting a dark palette
-- necessarily produces a light one. This set sits at 72, marginally darker than
-- normal.
--
-- What's preserved from the normal set is *structure*, since that's what the
-- eye reads at speed: road brighter than wall by a comparable margin (84 here,
-- 69 normally), checkpoint outline a step darker than its fill, and the two
-- gate colors split cool/warm so forward and reverse stay tellable apart.
local PALETTES               = {
  normal = {
    tiles     = {
      [0] = gfx.COLOR_DARK_BLUE, -- wall
      [1] = gfx.COLOR_INDIGO,    -- road
      [2] = gfx.COLOR_BLACK,     -- solid (also the stamped gate wall)
      [3] = gfx.COLOR_WHITE,
    },
    cp_fill   = gfx.COLOR_DARK_GREEN,
    cp_line   = gfx.COLOR_DARK_GRAY,
    cp_label  = gfx.COLOR_BLACK,
    gate_fwd  = gfx.COLOR_DARK_BLUE,
    gate_back = gfx.COLOR_DARK_PURPLE,
  },
  reverse = {
    tiles     = {
      -- Wall and solid trade places with the normal set: black wall, dark_blue
      -- solid. Keeps the two distinguishable where a stamped gate wall (tile 2)
      -- meets real wall, which is the one place they touch.
      [0] = gfx.COLOR_BLACK,
      [1] = gfx.COLOR_DARK_GREEN, -- teal road, the theme's whole tell
      [2] = gfx.COLOR_DARK_BLUE,
      [3] = gfx.COLOR_LIGHT_GRAY, -- the accent tile, off the blazing white
    },
    cp_fill   = gfx.COLOR_DARK_PURPLE,
    cp_line   = gfx.COLOR_DARK_BLUE,
    cp_label  = gfx.COLOR_BLACK,
    -- dark_green would be the hue-faithful forward gate but it's the road here,
    -- so forward borrows the normal theme's road violet instead.
    gate_fwd  = gfx.COLOR_INDIGO,
    gate_back = gfx.COLOR_BROWN,
  },
}

-- Fixed at load: REVERSE_MODE is a build-time flag, not something a race
-- toggles. gates.lua reads the gate colors off this (it already depends on
-- road transitively; road can't depend on gates without a cycle).
local COLORS                 = track_data.REVERSE_MODE and PALETTES.reverse or PALETTES.normal
local tile_colors            = COLORS.tiles

local CHECKPOINT_LABEL_SCALE = 2
local GHOST_ALPHA            = 0.6

local M                      = {}

M.COLORS                     = COLORS

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
        tile_colors[tile] or tile_colors[1])
    end
  end
end

function M.draw_checkpoint(cp, n, faded, total)
  local rect          = track_data.checkpoint_rect(cp)
  local outline_color = COLORS.cp_fill
  if not faded then
    outline_color = COLORS.cp_line
    gfx.rect_fill(rect.x, rect.y, rect.w, rect.h, COLORS.cp_fill)
  end
  gfx.rect(rect.x, rect.y, rect.w, rect.h, outline_color)

  if total and total <= 1 then return end

  local label  = tostring(n)
  local tw, th = usagi.measure_text(label)
  local tx     = math.floor(rect.x + (rect.w - tw * CHECKPOINT_LABEL_SCALE) / 2)
  local ty     = math.floor(rect.y + (rect.h - th * CHECKPOINT_LABEL_SCALE) / 2)
  gfx.text_ex(label, tx, ty, CHECKPOINT_LABEL_SCALE, 0, COLORS.cp_label,
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
-- `unlocked` and `unlocked2` are each list's own independent unlock count.
function M.draw_coins(id, unlocked, unlocked2, collected, lap)
  local tdata = track_data.TRACKS[id]
  local bob   = math.sin(usagi.elapsed * COIN_BOB_HZ * 2 * math.pi) * COIN_BOB_AMP
  draw_coin_list(tdata.coins, unlocked, collected and collected[1], COIN_SPRITE, bob)

  if not tdata.coins2 or track_data.effective_laps(id) < 2 then return end
  -- Full alpha with the bob frozen while lap 1 is still running. The bob is
  -- this game's "alive and collectable" tell, and low alpha already means
  -- *inactive* everywhere else (open gates, ghosts) - so a still, opaque coin
  -- says "real, but not yet" without spending the contrast against the road.
  local live = lap == nil or lap > 1
  draw_coin_list(tdata.coins2, unlocked2, collected and collected[2], COIN2_SPRITE,
    live and bob or 0, live and 1 or 0.3)
end

return M
