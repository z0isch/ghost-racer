local track_data = require "track_data"
local ghost      = require "ghost"

-- Per-track reference lines: a clean full-course lap recorded in a dev build and
-- stored as data/ref_<id>.json, used by the race rank meter as both an
-- arc-length progress ruler and a pace curve. The line carries a timestamp per
-- point plus per-checkpoint arc-length+time splits, so the meter projects the
-- finish rank against the reference's *pace shape* rather than assuming a
-- uniform speed. The reference's absolute speed doesn't matter - the projection
-- uses only ratios of reference times - so the lap only needs to be a clean,
-- representative racing line that visits every checkpoint in order. "Keep
-- fastest" capture is a heuristic for picking the most committed line.
--
-- Schema: { points: [{x,y,t}...], checkpoints: [{s,t}...] } where each
-- checkpoint split is the arc length (s) and reference time (t) at that
-- crossing. The old top-level `time` field is redundant - it equals the last
-- checkpoint's t.
local M = {}

-- Minimum spacing (px) between kept points when downsampling a raw per-frame
-- recording. Small enough to trace corners cleanly, large enough to keep the
-- file compact and the arc-length ruler smooth.
local MIN_SPACING = 6

-- Points ahead of the live cursor scanned each frame when mapping the car onto
-- the line. Forward-only within this window keeps progress monotonic (the line
-- can pass near itself) and the search cheap.
local SEARCH_WINDOW = 16

-- One reference per track, shared by every loop. The line's absolute speed and
-- coin route don't feed the projection (only ratios of reference times do), so
-- a single representative lap serves a coinless early loop and a coin-weaving
-- late one alike - the same bias already accepted between loop 2 and loop 20.
-- Keying the file to the loop only bought a slightly better pace shape, at the
-- cost of a missing file hiding the meter outright on any track/loop pair that
-- was never captured.
local function ref_rel(id) return "ref_" .. id .. ".json" end
local function ref_file(id) return "data/" .. ref_rel(id) end

-- Distance-based downsample of a recording (samples carry x,y,t) into a compact
-- polyline: always keep the first point, then any point at least MIN_SPACING
-- from the last kept one, and finally the true last position so the arc length
-- reaches the finish. Each kept point keeps its sample timestamp, which the
-- pace curve interpolates over.
local function downsample(recording)
  local pts  = {}
  local last = nil
  for _, s in ipairs(recording) do
    if not last then
      pts[#pts + 1] = { x = s.x, y = s.y, t = s.t }
      last          = s
    else
      local dx, dy = s.x - last.x, s.y - last.y
      if dx * dx + dy * dy >= MIN_SPACING * MIN_SPACING then
        pts[#pts + 1] = { x = s.x, y = s.y, t = s.t }
        last          = s
      end
    end
  end
  local fin = recording[#recording]
  if fin and last ~= fin then pts[#pts + 1] = { x = fin.x, y = fin.y, t = fin.t } end
  return pts
end

-- Cumulative arc length (px) at each point of a downsampled polyline; cum[1]=0.
local function cumulative(points)
  local cum = { [1] = 0 }
  for i = 2, #points do
    local dx = points[i].x - points[i - 1].x
    local dy = points[i].y - points[i - 1].y
    cum[i]   = cum[i - 1] + math.sqrt(dx * dx + dy * dy)
  end
  return cum
end

-- Arc length along `points` at reference time `t`, interpolating between the
-- two points that straddle it. Point timestamps are monotonic, so this walks
-- them in order.
local function arclen_at_time(points, cum, t)
  if t <= points[1].t then return 0 end
  local last = #points
  if t >= points[last].t then return cum[last] end
  for i = 1, last - 1 do
    local a, b = points[i], points[i + 1]
    if t >= a.t and t <= b.t then
      local span = b.t - a.t
      local f    = span > 0 and (t - a.t) / span or 0
      return cum[i] + f * (cum[i + 1] - cum[i])
    end
  end
  return cum[last]
end

-- Per-checkpoint {s,t} splits for a captured lap: the crossing times come from
-- the same in-order detector the ghost sim uses, and each crossing's arc length
-- is read off the downsampled polyline at that time so `s` is consistent with
-- the stored points. Returns nil if any owned checkpoint wasn't crossed (guarded
-- against upstream by full_course, but cheap to double-check).
local function cp_splits(points, recording, id)
  local checkpoints = track_data.TRACKS[id].checkpoints
  local crossings   = ghost.compute_cp_crossings(recording, checkpoints)
  if not crossings then return nil end
  local cum    = cumulative(points)
  local splits = {}
  for i = 1, #checkpoints do
    local c = crossings[i]
    if not c then return nil end
    splits[i] = { s = arclen_at_time(points, cum, c.t), t = c.t }
  end
  return splits
end

-- Loads the stored reference for a track ({ points, checkpoints }), or nil if
-- none is recorded (or it predates the pace-aware schema).
function M.load(id)
  local ok, data = pcall(usagi.read_json, ref_rel(id))
  if ok and data and data.points and #data.points > 0
      and data.checkpoints and #data.checkpoints > 0 then
    return data
  end
  return nil
end

-- Total lap time of a stored reference (its last checkpoint's split t), or nil.
local function ref_time(data)
  local cps = data and data.checkpoints
  return cps and #cps > 0 and cps[#cps].t or nil
end

local function write(id, points, splits)
  local f, err = io.open(ref_file(id), "w")
  if not f then
    print("[ref] failed to write " .. ref_file(id) .. ": " .. tostring(err))
    return false
  end
  f:write(usagi.to_json({ points = points, checkpoints = splits }))
  f:close()
  print(string.format("[ref] wrote %s (%d pts, %.2fs)", ref_file(id), #points, splits[#splits].t))
  return true
end

-- A lap is a valid reference only if it covered the whole course - every
-- checkpoint owned/crossed. A partial-ownership lap traces just part of the
-- track and must never become the ruler, so both capture paths refuse it.
local function full_course(id)
  local tstate = State.tracks[id]
  local total  = #track_data.TRACKS[id].checkpoints
  local owned  = tstate and tstate.checkpoints or 1
  return math.min(owned, total) >= total
end

-- Downsample + split a recording, returning (points, splits) or nil if the
-- crossings couldn't be resolved.
local function capture(id, recording)
  local points = downsample(recording)
  local splits = cp_splits(points, recording, id)
  if not splits then return nil end
  return points, splits
end

-- Auto-capture on a dev-build finish: overwrite the reference only when the lap
-- covered the full course and beat the stored time (or none exists).
function M.maybe_capture(id, recording, time)
  if not usagi.IS_DEV then return end
  if not recording or #recording == 0 then return end
  if not full_course(id) then return end
  -- A multi-lap recording can't become a reference: cp_splits resolves only the
  -- first N crossings out of a 2N-crossing run, so it would write lap-1 splits
  -- attached to two-lap points - a corrupt ruler. The stored refs are
  -- single-lap by definition and the whole lap-offset scheme below depends on
  -- them staying that way.
  if track_data.effective_laps(id) > 1 then return end
  local prev_t = ref_time(M.load(id))
  if prev_t and time >= prev_t then return end
  local points, splits = capture(id, recording)
  if not points then
    print("[ref] could not resolve checkpoint crossings for " .. tostring(id))
    return
  end
  write(id, points, splits)
end

-- Manual override (dev menu): capture this lap as the reference regardless of
-- time, but still refuse a partial-course lap since it would corrupt the ruler.
function M.force_capture(id, recording)
  if not recording or #recording == 0 then
    print("[ref] no finished lap to capture")
    return false
  end
  if not full_course(id) then
    print("[ref] refusing partial-course lap for " .. tostring(id) .. "; own all checkpoints first")
    return false
  end
  if track_data.effective_laps(id) > 1 then
    print("[ref] refusing multi-lap recording for " .. tostring(id) .. "; references are single-lap")
    return false
  end
  local points, splits = capture(id, recording)
  if not points then
    print("[ref] could not resolve checkpoint crossings for " .. tostring(id))
    return false
  end
  return write(id, points, splits)
end

-- Live progress ruler for the race in progress. Built from the active track's
-- reference; nil when no reference exists (the meter hides in that case).
--
-- The stored reference is always a single lap. A multi-lap race reuses that one
-- polyline per lap, with the finished laps' arc length and time folded into
-- `s_off` / `t_off` -- so the ruler measures a 2-lap race against a 2-lap
-- yardstick without duplicating the points in memory, and the one seam
-- discontinuity is handled at a known event (M.next_lap) instead of being left
-- for locate's nearest-point search window to stumble over.
local ruler = nil

-- Load the active track's reference and prime the ruler (cumulative arc
-- lengths + a forward-only search cursor). Call on race enter. Clears the
-- ruler when no reference is recorded for the track.
function M.begin(id)
  ruler      = nil
  local data = M.load(id)
  if not data then return end
  ruler = {
    points      = data.points,
    cum         = cumulative(data.points),
    checkpoints = data.checkpoints,
    cursor      = 1,
    laps        = track_data.effective_laps(id),
    lap         = 1,
    s_off       = 0,
    t_off       = 0,
  }
end

-- Roll the ruler over into the next lap: rewind the forward-only cursor to the
-- start of the line and bank the completed lap's arc length and time as an
-- offset. Called from the race scene when the lap increments.
--
-- Without this the cursor pins at the end of the line after the last
-- checkpoint: s_live would stick at s_N, t_ref at t_N, and the projection's
-- `remaining` at 0 - freezing the rank needle at a pegged 1.0 for the entire
-- second half of every race. That's worse than no meter, and it would make laps
-- feel bad for a reason that has nothing to do with laps.
function M.next_lap()
  if not ruler then return end
  local cp = ruler.checkpoints[#ruler.checkpoints]
  if not cp then return end
  ruler.lap    = ruler.lap + 1
  ruler.cursor = 1
  ruler.s_off  = ruler.s_off + cp.s
  ruler.t_off  = ruler.t_off + cp.t
end

-- Whether a reference ruler is active for the current race.
function M.has()
  return ruler ~= nil
end

-- Arc length (s_N) and reference time (t_N) at the finish - the last checkpoint
-- of the last lap - or nil if the ruler is missing or has no checkpoints.
function M.finish()
  if not ruler then return nil end
  local cp = ruler.checkpoints[#ruler.checkpoints]
  if not cp then return nil end
  return cp.s * ruler.laps, cp.t * ruler.laps
end

-- Map the live car at (x,y) onto the reference line and advance the forward-only
-- cursor. Returns the car's arc position s_live and the interpolated reference
-- time t_ref(s_live), both measured across the whole multi-lap race (the
-- current lap's position plus every finished lap's offset), or nil with no
-- ruler.
function M.locate(x, y)
  if not ruler then return nil end
  local pts, cum = ruler.points, ruler.cum
  local n        = #pts
  if n < 2 then return ruler.s_off, ruler.t_off + (pts[1] and pts[1].t or 0) end

  local lo = ruler.cursor
  local hi = math.min(n - 1, lo + SEARCH_WINDOW)
  local best_d2, best_i, best_ft
  for i = lo, hi do
    local a, b     = pts[i], pts[i + 1]
    local abx, aby = b.x - a.x, b.y - a.y
    local seg2     = abx * abx + aby * aby
    local ft       = 0
    if seg2 > 0 then
      ft = ((x - a.x) * abx + (y - a.y) * aby) / seg2
      if ft < 0 then ft = 0 elseif ft > 1 then ft = 1 end
    end
    local px, py = a.x + abx * ft, a.y + aby * ft
    local dx, dy = x - px, y - py
    local d2     = dx * dx + dy * dy
    if not best_d2 or d2 < best_d2 then
      best_d2, best_i, best_ft = d2, i, ft
    end
  end

  ruler.cursor = best_i
  local s      = cum[best_i] + best_ft * (cum[best_i + 1] - cum[best_i])
  local t_ref  = util.lerp(pts[best_i].t, pts[best_i + 1].t, best_ft)
  return ruler.s_off + s, ruler.t_off + t_ref
end

return M
