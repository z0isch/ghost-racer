-- Skill tree: permanent meta-upgrades bought between loops with a currency
-- separate from race $. Pure module - owns node defs, tree state, purchase
-- rules, and drawing. Run `usagi dev skill_tree_dev.lua` to try it. The game
-- earns ¥ via persist.LOOP_REWARD and consumes apply ctx in
-- persist.rederive_skill_effects.

local M     = {}

-- Node defs. `links` is authored one-directional here but treated as
-- undirected (adjacency is symmetrized at load). `entry = true` marks the
-- tree's starting node: always visible, always buyable.
-- Optional `locked = function(stats) -> reason|nil` gates buying beyond
-- adjacency: the node still reveals (loses its "?") via adjacency as usual,
-- but while the callback returns a reason string it can't be bought and the
-- popover shows the reason. `stats` is the game-owned table passed to draw.
-- Positions are game-space px centers on the 640x352 screen.
M.NODES     = {
  {
    id        = "top_speed",
    label     = "Engine Tune",
    desc      = "Increase top speed\nGotta go fast!",
    entry     = true,
    max       = 3,
    base_cost = 100,
    growth    = 1.5,
    pos       = { x = 240, y = 176 },
    links     = { "start_coins" },
    apply     = function(ctx, rank)
      ctx.top_speed = (ctx.top_speed or 0) + rank
    end,
  },
  {
    id        = "start_coins",
    label     = "Head Start",
    desc      = "Start with +1 coin on every track.\nEasy money!",
    max       = 1,
    base_cost = 100,
    growth    = 1.5,
    pos       = { x = 340, y = 140 },
    links     = {},
    locked    = function(stats)
      local loops = stats.loops or 0
      if loops < 2 then return "Finish 2 loops (" .. loops .. "/2)" end
    end,
    apply     = function(ctx, rank)
      ctx.start_coins = (ctx.start_coins or 0) + rank
    end,
  },
  {
    id        = "unlock_checkpoints",
    label     = "TSA Pre-check",
    desc      = "All checkpoints unlocked\nNo more taking out the liquids for you!",
    max       = 1,
    base_cost = 100,
    growth    = 1,
    pos       = { x = 340, y = 212 },
    links     = { "top_speed" },
    apply     = function(ctx, _rank)
      ctx.unlock_checkpoints = true
    end,
  }
}

-- Lookups built from M.NODES at require-time.
local BY_ID = {}
local ADJ   = {}

for _, def in ipairs(M.NODES) do
  BY_ID[def.id] = def
  ADJ[def.id]   = ADJ[def.id] or {}
end

-- Symmetrize links: each authored pair adds both directions. A link to an
-- unknown id is a typo in the defs, so fail loudly at require-time.
local function add_adj(a, b)
  for _, existing in ipairs(ADJ[a]) do
    if existing == b then return end
  end
  table.insert(ADJ[a], b)
end

for _, def in ipairs(M.NODES) do
  for _, other in ipairs(def.links) do
    if not BY_ID[other] then
      error("skill_tree: node '" .. def.id .. "' links to unknown id '"
        .. other .. "'")
    end
    add_adj(def.id, other)
    add_adj(other, def.id)
  end
end

-- Drawing constants.
local NODE_SIZE   = 32
local FX_SECS     = 0.25
local POPOVER_W   = 150
local POPOVER_PAD = 4
local PIP_SIZE    = 3
local PIP_GAP     = 5
local SHAKE_AMP   = 2 -- px of deny-shake jitter on x
local PULSE_SPEED = 4 -- rad/sec of the buyable border pulse

-- Fresh tree state. Plain serializable table: when the tree is wired into
-- the real game this whole table can go into persist.lua's progression as-is
-- (minus `fx`, which is transient render state and must be stripped/rebuilt).
function M.new(opts)
  return {
    points = opts and opts.points or 0,
    ranks  = {}, -- id -> rank (absent = 0)
    fx     = {}, -- id -> { kind = "flash"|"deny", until_t = <usagi.elapsed> }
  }
end

function M.rank(st, id)
  return st.ranks[id] or 0
end

function M.is_owned(st, id)
  return M.rank(st, id) >= 1
end

-- Adjacency reveal: entry nodes and neighbors of owned nodes. Governs only
-- the "?" fog - a revealed node may still be locked by its def's `locked`.
function M.is_revealed(st, id)
  if BY_ID[id].entry then return true end
  for _, neighbor in ipairs(ADJ[id]) do
    if M.is_owned(st, neighbor) then return true end
  end
  return false
end

-- Why the node's extra gate is shut, or nil when it isn't (or has none).
-- Takes st for signature consistency with the other rule queries.
function M.lock_reason(_st, id, stats)
  local def = BY_ID[id]
  if def.locked then return def.locked(stats or {}) end
  return nil
end

function M.is_unlocked(st, id, stats)
  return M.is_revealed(st, id) and M.lock_reason(st, id, stats) == nil
end

-- Visibility follows reveal, not unlock: an extra-locked node draws full
-- (with its reason in the popover) rather than as a "?".
function M.is_visible(st, id)
  return M.is_owned(st, id) or M.is_revealed(st, id)
end

-- Cost of the next rank, or nil when already maxed.
function M.next_cost(st, id)
  local def = BY_ID[id]
  local rank = M.rank(st, id)
  if rank >= def.max then return nil end
  return math.floor(def.base_cost * def.growth ^ rank)
end

local function set_fx(st, id, kind)
  st.fx[id] = { kind = kind, until_t = usagi.elapsed + FX_SECS }
end

local function fx_active(st, id, kind)
  local fx = st.fx[id]
  return fx ~= nil and fx.kind == kind and fx.until_t > usagi.elapsed
end

-- Attempt to buy the next rank of `id`. Returns ok, err where err is one of
-- "hidden" | "locked" | "max" | "poor". Check order: hidden -> max -> locked
-- -> poor (see plan). Callbacks never run here - only apply_all runs them.
function M.try_buy(st, id, stats)
  if not M.is_visible(st, id) then return false, "hidden" end
  local cost = M.next_cost(st, id)
  if cost == nil then return false, "max" end
  if not M.is_unlocked(st, id, stats) then
    set_fx(st, id, "deny")
    sfx.play_ex("coin", 0.6, 0.5, 0)
    return false, "locked"
  end
  if st.points < cost then
    set_fx(st, id, "deny")
    sfx.play_ex("coin", 0.6, 0.5, 0)
    return false, "poor"
  end
  st.points = st.points - cost
  st.ranks[id] = M.rank(st, id) + 1
  set_fx(st, id, "flash")
  sfx.play("coin")
  return true
end

-- Run every owned node's apply(ctx, rank) once, in def order. Returns ctx.
function M.apply_all(st, ctx)
  for _, def in ipairs(M.NODES) do
    local rank = M.rank(st, def.id)
    if rank >= 1 then def.apply(ctx, rank) end
  end
  return ctx
end

-- Immediate-mode: draws the whole tree and handles hover/click itself. Call
-- from _draw. No M.update - animation is driven off usagi.elapsed and fx
-- entries carry an absolute expiry, so there's no per-frame bookkeeping.
local active = nil -- id of the currently armed node (cleared on mouse release)

-- Draws a small filled/empty pip square at (x, y).
local function draw_pip(x, y, filled)
  if filled then
    gfx.rect_fill(x, y, PIP_SIZE, PIP_SIZE, gfx.COLOR_WHITE)
  else
    gfx.rect(x, y, PIP_SIZE, PIP_SIZE, gfx.COLOR_LIGHT_GRAY)
  end
end

-- Card anchored beside the hovered node. Only called for visible nodes.
local function draw_popover(st, id, rect, stats)
  local def    = BY_ID[id]
  local rank   = M.rank(st, id)
  local cost   = M.next_cost(st, id)
  local reason = M.lock_reason(st, id, stats)
  local _, lh  = usagi.measure_text("A")

  -- Build the rows top-to-bottom, so height and width fall out of one list.
  local rows   = {}
  table.insert(rows, {
    kind = "label",
    text = def.label,
    scale = 2,
    color = gfx.COLOR_WHITE
  })
  -- While the extra gate is shut, tease only the title and cost - what the
  -- ability actually does stays hidden until it's unlocked.
  if not reason then
    for line in (def.desc .. "\n"):gmatch("(.-)\n") do
      table.insert(rows, {
        kind = "text",
        text = line,
        scale = 1,
        color = gfx.COLOR_LIGHT_GRAY
      })
    end
    if def.max > 1 then
      table.insert(rows, { kind = "pips" })
    elseif M.is_owned(st, id) then
      table.insert(rows, {
        kind = "text",
        text = "Owned",
        scale = 1,
        color = gfx.COLOR_GREEN
      })
    end
  end
  if cost == nil then
    table.insert(rows, {
      kind = "text",
      text = "MAX",
      scale = 1,
      color = gfx.COLOR_GREEN
    })
  else
    local afford = st.points >= cost
    table.insert(rows, {
      kind = "text",
      text = "Cost: " .. cost .. " ¥",
      scale = 1,
      color = afford and gfx.COLOR_YELLOW or gfx.COLOR_RED
    })
  end
  if reason then
    table.insert(rows, {
      kind = "text",
      text = "Locked: " .. reason,
      scale = 1,
      color = gfx.COLOR_RED
    })
  elseif not M.is_revealed(st, id) then
    -- Unreachable while visibility == reveal (decision 5), kept coded so the
    -- popover stays correct if the rules ever diverge.
    local parent = ADJ[id][1]
    local plabel = parent and BY_ID[parent].label or "?"
    table.insert(rows, {
      kind = "text",
      text = "Requires: " .. plabel,
      scale = 1,
      color = gfx.COLOR_RED
    })
  end

  -- Measure the content box.
  local pips_w = def.max * PIP_GAP + 4 + usagi.measure_text(rank .. "/" .. def.max)
  local content_w, content_h = 0, 0
  for _, row in ipairs(rows) do
    local rw, rh
    if row.kind == "pips" then
      rw, rh = pips_w, lh
    else
      rw = usagi.measure_text(row.text) * row.scale
      rh = lh * row.scale
    end
    content_w = math.max(content_w, rw)
    content_h = content_h + rh
  end
  local box_w = math.max(POPOVER_W, content_w + POPOVER_PAD * 2)
  local box_h = content_h + POPOVER_PAD * 2

  -- Anchor right of the node, flipping left near the edge, clamped vertically.
  local x = rect.x + rect.w + 6
  if x + box_w > usagi.GAME_W then x = rect.x - 6 - box_w end
  local y = rect.y
  if y + box_h > usagi.GAME_H then y = usagi.GAME_H - box_h end
  if y < 0 then y = 0 end

  gfx.rect_fill(x, y, box_w, box_h, gfx.COLOR_BLACK, 0.85)
  gfx.rect(x, y, box_w, box_h, gfx.COLOR_WHITE)

  local cx = x + POPOVER_PAD
  local cy = y + POPOVER_PAD
  for _, row in ipairs(rows) do
    if row.kind == "pips" then
      for i = 1, def.max do
        draw_pip(cx + (i - 1) * PIP_GAP, cy + math.floor((lh - PIP_SIZE) / 2),
          i <= rank)
      end
      gfx.text(rank .. "/" .. def.max, cx + def.max * PIP_GAP + 4, cy,
        gfx.COLOR_WHITE)
      cy = cy + lh
    else
      gfx.text_ex(row.text, cx, cy, row.scale, 0, row.color, 1)
      cy = cy + lh * row.scale
    end
  end
end

-- Draws one node square (with fog / owned / buyable state) at its position.
-- Returns the node's screen rect so the caller can hit-test and place popovers.
local function draw_node(st, def, stats)
  local id      = def.id
  local rank    = M.rank(st, id)
  local visible = M.is_visible(st, id)
  local owned   = M.is_owned(st, id)
  local cost    = M.next_cost(st, id)
  local maxed   = cost == nil
  local afford  = cost ~= nil and st.points >= cost
  local locked  = M.lock_reason(st, id, stats) ~= nil

  local dx      = 0
  if fx_active(st, id, "deny") then
    dx = math.sin(usagi.elapsed * 60) * SHAKE_AMP
  end
  local x = def.pos.x - NODE_SIZE / 2 + dx
  local y = def.pos.y - NODE_SIZE / 2

  if not visible then
    gfx.rect_fill(x, y, NODE_SIZE, NODE_SIZE, gfx.COLOR_DARK_GRAY)
    gfx.rect(x, y, NODE_SIZE, NODE_SIZE, gfx.COLOR_LIGHT_GRAY)
    local qw, qh = usagi.measure_text("?")
    gfx.text_ex("?", x + (NODE_SIZE - qw * 2) / 2, y + (NODE_SIZE - qh * 2) / 2,
      2, 0, gfx.COLOR_LIGHT_GRAY, 1)
    return { x = x, y = y, w = NODE_SIZE, h = NODE_SIZE }
  end

  local fill, border, label_color = gfx.COLOR_INDIGO, gfx.COLOR_WHITE,
      gfx.COLOR_WHITE
  if owned then
    fill   = gfx.COLOR_DARK_GREEN
    border = maxed and gfx.COLOR_YELLOW or gfx.COLOR_GREEN
  elseif locked then
    -- Revealed but gated by def.locked: muted, no buyable pulse; the hover
    -- popover carries the reason.
    border      = gfx.COLOR_LIGHT_GRAY
    label_color = gfx.COLOR_LIGHT_GRAY
  elseif not afford then
    label_color = gfx.COLOR_LIGHT_GRAY
  end

  gfx.rect_fill(x, y, NODE_SIZE, NODE_SIZE, fill)
  if not owned and not locked and afford then
    -- Buyable + affordable: pulse the border alpha to draw the eye.
    local pulse = 0.6 + 0.4 * math.abs(math.sin(usagi.elapsed * PULSE_SPEED))
    gfx.rect_ex(x, y, NODE_SIZE, NODE_SIZE, 1, border, pulse)
  else
    gfx.rect(x, y, NODE_SIZE, NODE_SIZE, border)
  end

  local icon = def.icon or def.label:sub(1, 1)
  local iw, ih = usagi.measure_text(icon)
  gfx.text_ex(icon, x + (NODE_SIZE - iw * 2) / 2, y + (NODE_SIZE - ih * 2) / 2,
    2, 0, label_color, 1)

  -- Rank pips under owned nodes.
  if owned then
    local total_w = def.max * PIP_GAP - (PIP_GAP - PIP_SIZE)
    local px = def.pos.x + dx - total_w / 2
    local py = y + NODE_SIZE + 3
    for i = 1, def.max do
      draw_pip(px + (i - 1) * PIP_GAP, py, i <= rank)
    end
  end

  -- Flash overdraw fading over FX_SECS.
  if fx_active(st, id, "flash") then
    local fx    = st.fx[id]
    local alpha = (fx.until_t - usagi.elapsed) / FX_SECS
    gfx.rect_fill(x, y, NODE_SIZE, NODE_SIZE, gfx.COLOR_TRUE_WHITE, alpha)
  end

  return { x = x, y = y, w = NODE_SIZE, h = NODE_SIZE }
end

-- Draws everything and handles hover/click. Call once from _draw. `stats`
-- is an optional game-owned table of progress facts (e.g. loops completed)
-- consumed by node `locked` callbacks.
function M.draw(st, stats)
  stats = stats or {}
  -- Links first, under every node.
  for _, def in ipairs(M.NODES) do
    for _, other in ipairs(def.links) do
      local a, b = def.pos, BY_ID[other].pos
      local lit = M.is_owned(st, def.id) or M.is_owned(st, other)
      gfx.line_ex(a.x, a.y, b.x, b.y, 2,
        lit and gfx.COLOR_LIGHT_GRAY or gfx.COLOR_DARK_GRAY)
    end
  end

  local mx, my     = input.mouse()
  local mouse      = { x = mx, y = my }
  local in_win     = mx >= 0 and mx < usagi.GAME_W and my >= 0 and my < usagi.GAME_H
  local hovered_id = nil

  for _, def in ipairs(M.NODES) do
    local rect    = draw_node(st, def, stats)
    local visible = M.is_visible(st, def.id)
    local hovered = visible and in_win and util.point_in_rect(mouse, rect)

    if hovered then
      hovered_id = def.id
      if input.mouse_pressed(input.MOUSE_LEFT) then active = def.id end
    end
    if input.mouse_released(input.MOUSE_LEFT) then
      if active == def.id and hovered then M.try_buy(st, def.id, stats) end
      if active == def.id then active = nil end
    end
  end

  if hovered_id then
    draw_popover(st, hovered_id, {
      x = BY_ID[hovered_id].pos.x - NODE_SIZE / 2,
      y = BY_ID[hovered_id].pos.y - NODE_SIZE / 2,
      w = NODE_SIZE,
      h = NODE_SIZE,
    }, stats)
  end

  -- Points HUD, top-left. Drawn by the module so any future scene gets it free.
  gfx.text_ex("¥ " .. st.points, 8, 8, 2, 0, gfx.COLOR_YELLOW, 1)
end

return M
