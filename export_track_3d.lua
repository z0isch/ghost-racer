-- Exports track 3 into the shape `3d/src/io/types.ts` fixes, for the 3D kart
-- prototype in `3d/` (T3, issue #4).
--
-- Run it from the repo root:
--
--     lua export_track_3d.lua
--
-- and it writes `3d/data/track3.json`.
--
-- ## Why a standalone script rather than a dev scene
--
-- The ticket first imagined this running under `usagi dev`. It doesn't: `usagi`
-- has no headless script runner (`usagi --help` lists run/dev/tools/export
-- only), so a dev scene would mean opening a game window and pressing a key
-- every time the 3D side discovers a field the export dropped. Re-runnability
-- is the requirement that matters here, so this runs under stock Lua instead.
--
-- Nothing it touches needs the engine. `track_data.lua` and `tile-map/track3.lua`
-- are pure data modules — no `gfx`, no `usagi` — and the two engine calls this
-- would otherwise want (`usagi.read_json` / `usagi.to_json`) are replaced by the
-- decoder and the writer below. `road.lua` is deliberately *not* required: it
-- pulls in `gfx` for the palette, and the one thing this needs from it — the
-- tile-id meaning — is already transcribed into `types.ts`.
--
-- ## What it does not export
--
-- See the `ExcludedFromExport` block at the bottom of `types.ts`: `coins2`,
-- gates, the rank ladder and economy fields, the reference lap's `{s, t}`
-- checkpoint splits, `label`, and `REVERSE_MODE` mirroring. Track 3 only.

local track_data  = require "track_data"

local TRACK_ID    = "track3"
local SCHEMA      = 1
local REF_IN      = "data/ref_" .. TRACK_ID .. ".json"
local OUT         = "3d/data/" .. TRACK_ID .. ".json"

-- Tile ids that may appear in an exported layer, mirroring `types.ts`'s `Tile`.
-- An unknown id is a hard error rather than a pass-through: the 3D collision
-- test keys off these, and a silently-carried id 4 would be drivable on one side
-- and solid on the other.
local KNOWN_TILES = { [0] = true, [1] = true, [2] = true, [3] = true }

-- `car.reset` hardcodes `facing_angle = 0` for every track (`car.lua:142`).
-- That hardcode is a decision *about track 3* — it points the car down the top
-- straight — so it ships as track data rather than staying buried in the car
-- port. See `Spawn.facing` in `types.ts`.
local SPAWN_FACING = 0

local function fail(msg, ...)
  io.stderr:write("[export_track_3d] " .. string.format(msg, ...) .. "\n")
  os.exit(1)
end

-- ---------------------------------------------------------------------------
-- JSON decode, just enough for `data/ref_<id>.json`
--
-- Only needed because the reference lap is captured through the engine and lands
-- as JSON. Covers the subset `usagi.to_json` emits: objects, arrays, numbers,
-- strings without escapes beyond the standard set, and the three literals.
-- ---------------------------------------------------------------------------

local decode_value

local ESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f",
  n = "\n", r = "\r", t = "\t" }

local function skip_space(s, i)
  local _, j = s:find("^[ \t\r\n]*", i)
  return j + 1
end

local function decode_string(s, i)
  i = i + 1 -- opening quote
  local out = {}
  while true do
    local c = s:sub(i, i)
    if c == "" then fail("unterminated string in %s", REF_IN) end
    if c == '"' then return table.concat(out), i + 1 end
    if c == "\\" then
      local e = s:sub(i + 1, i + 1)
      if e == "u" then
        -- No \u in any reference capture; refuse rather than half-decode it.
        fail("\\u escapes are not supported (%s)", REF_IN)
      end
      local lit = ESCAPES[e] or fail("bad escape \\%s in %s", e, REF_IN)
      out[#out + 1] = lit
      i = i + 2
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
end

local function decode_number(s, i)
  local literal = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
  local n = literal and tonumber(literal)
  if not n then fail("bad number at byte %d of %s", i, REF_IN) end
  return n, i + #literal
end

local function decode_array(s, i)
  local out, n = {}, 0
  i = skip_space(s, i + 1)
  if s:sub(i, i) == "]" then return out, i + 1 end
  while true do
    local v
    v, i = decode_value(s, i)
    n = n + 1
    out[n] = v
    i = skip_space(s, i)
    local c = s:sub(i, i)
    if c == "]" then return out, i + 1 end
    if c ~= "," then fail("expected ',' or ']' at byte %d of %s", i, REF_IN) end
    i = skip_space(s, i + 1)
  end
end

local function decode_object(s, i)
  local out = {}
  i = skip_space(s, i + 1)
  if s:sub(i, i) == "}" then return out, i + 1 end
  while true do
    if s:sub(i, i) ~= '"' then fail("expected key at byte %d of %s", i, REF_IN) end
    local k
    k, i = decode_string(s, i)
    i = skip_space(s, i)
    if s:sub(i, i) ~= ":" then fail("expected ':' at byte %d of %s", i, REF_IN) end
    i = skip_space(s, i + 1)
    out[k], i = decode_value(s, i)
    i = skip_space(s, i)
    local c = s:sub(i, i)
    if c == "}" then return out, i + 1 end
    if c ~= "," then fail("expected ',' or '}' at byte %d of %s", i, REF_IN) end
    i = skip_space(s, i + 1)
  end
end

decode_value = function(s, i)
  local c = s:sub(i, i)
  if c == "{" then return decode_object(s, i) end
  if c == "[" then return decode_array(s, i) end
  if c == '"' then return decode_string(s, i) end
  if s:sub(i, i + 3) == "true" then return true, i + 4 end
  if s:sub(i, i + 4) == "false" then return false, i + 5 end
  if s:sub(i, i + 3) == "null" then return nil, i + 4 end
  return decode_number(s, i)
end

-- Returns the decoded root, which every caller here expects to be an object.
local function decode_json(text)
  local v, i = decode_value(text, skip_space(text, 1))
  i = skip_space(text, i)
  if i <= #text then fail("trailing content at byte %d of %s", i, REF_IN) end
  if type(v) ~= "table" then fail("%s is not a JSON object", REF_IN) end
  return v
end

-- ---------------------------------------------------------------------------
-- JSON encode
--
-- Hand-rolled rather than generic so key order is fixed and the tile grid lays
-- out one map row per line. This file is checked in and re-exported often; a
-- stable, readable diff is the point.
-- ---------------------------------------------------------------------------

-- Shortest decimal form that reads back as the identical double, so a re-export
-- of an unchanged reference lap is a no-op diff and no capture precision is
-- silently rounded away.
local function num(v)
  if v == math.floor(v) and math.abs(v) < 1e15 then
    return string.format("%d", v)
  end
  for _, prec in ipairs { 14, 15, 16, 17 } do
    local s = string.format("%." .. prec .. "g", v)
    if tonumber(s) == v then return s end
  end
  return string.format("%.17g", v)
end

local function point_json(p)
  return string.format('{ "t": %s, "x": %s, "y": %s }', num(p.t), num(p.x), num(p.y))
end

-- ---------------------------------------------------------------------------
-- The export
-- ---------------------------------------------------------------------------

if track_data.REVERSE_MODE then
  -- `track_data` swaps every track for its mirrored twin at load when this is
  -- on, but the captured reference lap is never mirrored — the export would pair
  -- a flipped grid with a forward lap and the seeded ghosts would sit in walls.
  fail("track_data.REVERSE_MODE is on; the reference lap is not mirrored. Set it false and re-run.")
end

local tdata = track_data.TRACKS[TRACK_ID]
if not tdata then fail("no track %q in track_data.TRACKS", TRACK_ID) end

local ts = track_data.tile_size
local map = tdata.map
local layer = map.layers[1]

if #map.layers ~= 1 then
  fail("expected 1 tile layer, got %d — the export flattens to a single grid", #map.layers)
end
if #layer.data ~= map.width * map.height then
  fail("layer has %d tiles, expected %d (%dx%d)", #layer.data, map.width * map.height,
    map.width, map.height)
end
for i, tile in ipairs(layer.data) do
  if not KNOWN_TILES[tile] then
    local idx = i - 1
    fail("unknown tile id %d at col %d row %d; teach types.ts about it first",
      tile, idx % map.width, math.floor(idx / map.width))
  end
end

local ref_text = assert(io.open(REF_IN, "r"), REF_IN .. " not found (run from the repo root)")
local ref = decode_json(ref_text:read("*a"))
ref_text:close()
if not ref.points or #ref.points == 0 then
  fail("%s has no points; capture a reference lap first (Dev: Save Reference Lap)", REF_IN)
end

-- The reference lap was recorded straight off `car.x`/`car.y` from the spawn
-- pose, so its first sample is the spawn tile's top-left corner. If that stops
-- holding, one of the two moved and the seeded ghost chain is about to start in
-- the wrong place — which is a silent half-lap of drift, not a crash.
local first = ref.points[1]
local sx, sy = tdata.spawn.col * ts, tdata.spawn.row * ts
if first.x ~= sx or first.y ~= sy then
  fail("reference lap starts at (%s, %s) but spawn is (%d, %d); recapture the lap",
    num(first.x), num(first.y), sx, sy)
end

local out = {}
local function w(line) out[#out + 1] = line end

w("{")
w(string.format('  "schemaVersion": %d,', SCHEMA))
w(string.format('  "id": "%s",', TRACK_ID))
w(string.format('  "tileSize": %d,', ts))
w('  "map": {')
w(string.format('    "width": %d,', map.width))
w(string.format('    "height": %d,', map.height))
w('    "tiles": [')
for row = 0, map.height - 1 do
  local cells = {}
  for col = 0, map.width - 1 do
    cells[col + 1] = string.format("%d", layer.data[row * map.width + col + 1])
  end
  local comma = row < map.height - 1 and "," or ""
  w("      " .. table.concat(cells, ", ") .. comma)
end
w("    ]")
w("  },")
w(string.format('  "spawn": { "col": %d, "row": %d, "facing": %s },',
  tdata.spawn.col, tdata.spawn.row, num(SPAWN_FACING)))

w('  "checkpoints": [')
for i, cp in ipairs(tdata.checkpoints) do
  w(string.format('    { "col": %d, "row": %d, "w": %d, "h": %d }%s',
    cp.col, cp.row, cp.w, cp.h, i < #tdata.checkpoints and "," or ""))
end
w("  ],")

w('  "coins": [')
for i, coin in ipairs(tdata.coins) do
  w(string.format('    { "col": %d, "row": %d }%s',
    coin.col, coin.row, i < #tdata.coins and "," or ""))
end
w("  ],")

w('  "referenceLap": {')
w('    "points": [')
for i, p in ipairs(ref.points) do
  w("      " .. point_json(p) .. (i < #ref.points and "," or ""))
end
w("    ]")
w("  }")
w("}")

local f = assert(io.open(OUT, "w"), "cannot write " .. OUT .. " (does 3d/data/ exist?)")
f:write(table.concat(out, "\n"), "\n")
f:close()

print(string.format(
  "[export_track_3d] wrote %s: %dx%d tiles, %d checkpoints, %d coins, %d reference points (%.2fs lap)",
  OUT, map.width, map.height, #tdata.checkpoints, #tdata.coins, #ref.points,
  ref.points[#ref.points].t))
