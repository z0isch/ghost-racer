/**
 * The ghost field: the promoted line, the layout along it, and the recording
 * that produces the next one (T10, issue #11).
 *
 * Ported from `endless_dev.lua` — `ideal_line` (:237), `time_at_dist` (:272),
 * `set_offsets` (:297), `set_line` (:312), `ghost_pose` (:342), the `taken`
 * bookkeeping inside `contact` (:398-446) — plus `ghost.sample_at`
 * (`ghost.lua:212`) and `reference.lua`'s `downsample` (:45).
 *
 * All of it is 2D polyline math over `{t, x, y}`, which is why it survives the
 * move to 3D untouched: nothing here knows the field will be drawn as karts.
 *
 * ## Ghosts are pickups, not hazards
 *
 * `endless_dev.lua` was built to answer whether *dodging* oncoming ghosts felt
 * good. The prototype inverts it: `ghostSpeed` 0 and `sameDir` on, so the field
 * is a set of stationary karts parked along your own best line, and retracing
 * that line precisely collects all of them. That inversion is the whole game,
 * and it is the reason `set_offsets` matters as much as it does — see below.
 *
 * ## Laid out by distance, not by time
 *
 * Time-even offsets clump wherever the promoted lap was *slow*: corners eat lap
 * time, so they would collect ghosts, and the straights would go bare. Spacing
 * by arc length puts the same number of car lengths between neighbours
 * everywhere. Offsets are still *stored* as times, because a phase is what the
 * line is sampled with.
 *
 * ## The recording is raw; the line is downsampled
 *
 * A lap records one sample per fixed step — at 120Hz a 40-second lap is ~4,800
 * points — and `promote()` downsamples that to the 6px `MIN_SPACING` polyline
 * `reference.lua:45` produces, keeping each retained point's original timestamp.
 * In-lap fidelity costs nothing; the compaction is paid once per rollover.
 *
 * The promoted line and the seeded reference lap must share **one** format, or
 * `HEADING_DT` papers over lerp noise at two different resolutions and ghost
 * facing angles jitter differently depending on which source a ghost came from.
 * See `io/types.ts`'s `LinePoint`, which is that one format.
 */

import * as angle from "./angle.js";
import { CAR_SIZE } from "./car.js";
import { MAX_GHOSTS, TUNE } from "./tune.js";
import type { GhostLine } from "./lap.js";
import type { LinePoint, TrackExport } from "../io/types.js";

/**
 * Lookahead used to read a ghost's *travel* direction off its line
 * (`endless_dev.lua:56`). Small enough to be the local tangent, large enough to
 * clear `sampleAt`'s lerp noise between distance-downsampled points.
 */
export const HEADING_DT = 0.05;

/**
 * Minimum spacing in source pixels between kept points when downsampling a raw
 * recording (`reference.lua:23`). The reference lap in the export is already at
 * this spacing; a promoted lap has to arrive at it too.
 */
export const MIN_SPACING = 6;

/**
 * Keep the field off the start/finish line, measured in car lengths of arc
 * length (`endless_dev.lua:68`).
 *
 * On a closed loop "near the start" and "near the end" of the lap are the same
 * neighbourhood — phase 0 — because the line wraps seamlessly there. The car
 * respawns on the line's own start pose at every grid start, so a ghost sitting
 * at phase 0 would be free money the instant the lights change. One symmetric
 * gap carved off both ends covers both sides of the wrap.
 */
export const START_GAP_LENGTHS = 3;

/** Where a ghost is and which way it points. Position is a top-left corner. */
export interface GhostPose {
  /** Source pixels, east. */
  readonly x: number;
  /** Source pixels, south — `LinePoint.y` in the sim's `z` naming. */
  readonly z: number;
  /** Travel heading in radians, already flipped for `sameDir`. */
  readonly head: number;
}

/**
 * The ghost field. Implements `lap.ts`'s `GhostLine` — that interface is the
 * whole of the lap/ghost seam, and everything past it (polylines, arc length,
 * `taken`) is this file's business alone.
 */
export interface GhostField extends GhostLine {
  /**
   * The line the field is riding: the seeded reference lap until the first
   * promotion, the player's own best lap after. `render/track.ts` draws it as
   * the ground ribbon; nothing else should hold onto the array across a
   * rollover, since `promote()` replaces it wholesale.
   */
  readonly line: readonly LinePoint[];
  /**
   * Bumped every time `line` is replaced, so a renderer can rebuild its geometry
   * on change rather than per frame.
   */
  readonly lineVersion: number;
  /** Ghosts currently laid out: `TUNE.ghosts`, clamped and re-laid on change. */
  readonly count: number;

  /**
   * One fixed step: advance the lap clock and append a raw sample. Call it
   * *after* `lap.endStep`, mirroring `endless_dev.lua:655-657` — a step that
   * rolls the lap over records its sample into the new lap, not the finished
   * one.
   */
  step(dt: number, x: number, z: number): void;

  /**
   * Pose of ghost `i`, or `null` if it is out of range or already taken this
   * lap. Taken ghosts vanish from posing entirely, which is what drops them out
   * of both contact and draw (`endless_dev.lua:413`, `:692`).
   */
  pose(i: number): GhostPose | null;

  /**
   * Pose of the non-interactive **pace ghost** (`endless_dev.lua:366`): the
   * promoted line sampled at the player's *own* lap clock, so it always shows
   * where that lap was at the same elapsed time. Forward, real time, no
   * `ghostSpeed` or `sameDir` involved — it is a reference, not part of the
   * field, and `take`/`touched` never apply to it.
   *
   * `null` when there is no line, or when `TUNE.paceGhost` is off.
   *
   * This arrived with T11 rather than T10 because T10 built the *field* and the
   * pace ghost is not in it. It is here rather than in the renderer because it
   * is polyline math over the promoted line, which is this file's business.
   */
  pacePose(): GhostPose | null;

  /**
   * Consume ghost `i` for the rest of the lap. Each ghost is worth exactly one
   * hit — otherwise the car could sit inside one farming boosts — and the whole
   * field comes back at `rollover()`. T12's contact test is the caller.
   */
  take(i: number): void;

  /**
   * Overlap edge state for ghost `i`, so T12's contact test fires on the
   * *rising* edge. Kept here rather than in the contact test because it is
   * per-ghost lap state, cleared by the same rollover that restores `taken`.
   */
  touched(i: number): boolean;
  setTouched(i: number, value: boolean): void;
}

export function createGhosts(track: TrackExport): GhostField {
  /** The installed line, its cumulative arc length, and per-point headings. */
  let line: readonly LinePoint[] = [];
  let cum: number[] = [];
  let headings: number[] = [];
  let period = 0;
  let lineVersion = 0;

  /** Phases, one per ghost, laid out by `setOffsets`. */
  let offsets: number[] = [];
  /** The `TUNE.ghosts` the current `offsets` were laid for. */
  let laidFor = -1;

  /** The lap in progress: its clock, and every sample of it so far. */
  let lapT = 0;
  let recording: LinePoint[] = [];

  let taken: boolean[] = [];
  let touching: boolean[] = [];

  /**
   * `time_at_dist` — the time along the line at cumulative distance `d`, by
   * walking `cum` and lerping the bracketing points' timestamps. This is what
   * turns an arc-length placement into a phase the rest of the file can sample
   * with.
   */
  function timeAtDist(d: number): number {
    if (cum.length < 2) return 0;
    const total = cum[cum.length - 1]!;
    const clamped = Math.max(0, Math.min(total, d));
    for (let i = 1; i < cum.length; i++) {
      if (cum[i]! >= clamped) {
        const span = cum[i]! - cum[i - 1]!;
        const f = span > 0 ? (clamped - cum[i - 1]!) / span : 0;
        return line[i - 1]!.t + (line[i]!.t - line[i - 1]!.t) * f;
      }
    }
    return line[line.length - 1]!.t;
  }

  /**
   * `set_offsets` — disperse `TUNE.ghosts` ghosts through the line's arc length,
   * minus the start gap at both ends. `range` is the stretch of best line the
   * field actually occupies; each ghost sits at the centre of its own slice of
   * it, so the spacing is even and no ghost lands on either boundary.
   */
  function setOffsets(): void {
    const n = ghostCount();
    laidFor = n;
    offsets = [];
    const total = cum.length > 0 ? cum[cum.length - 1]! : 0;
    if (total <= 0 || n <= 0) return;

    const gap = Math.min(START_GAP_LENGTHS * CAR_SIZE, total / 2);
    const range = total - 2 * gap;
    for (let i = 0; i < n; i++) {
      const d = gap + (range > 0 ? ((i + 0.5) / n) * range : 0);
      offsets.push(timeAtDist(d));
    }
  }

  /** `TUNE.ghosts` as an index count: a whole number inside the authored range. */
  function ghostCount(): number {
    return Math.max(0, Math.min(MAX_GHOSTS, Math.floor(TUNE.ghosts)));
  }

  /**
   * `set_line` — install a line, rebuild its cumulative-distance table, and
   * re-lay the field on it.
   *
   * Headings are derived here and nowhere else. `LinePoint` carries no angle
   * (the capture never recorded one), so each point takes the direction to its
   * neighbour, with a coincident pair — the car stopped — carrying the last real
   * heading forward rather than snapping east. That is `ghost.line_from_reference`
   * (`ghost.lua:263`), moved to the one place both line sources pass through.
   */
  function setLine(points: readonly LinePoint[]): void {
    line = points;
    period = points.length > 0 ? points[points.length - 1]!.t : 0;

    cum = new Array<number>(points.length);
    headings = new Array<number>(points.length);
    let carried = 0;
    for (let i = 0; i < points.length; i++) {
      const p = points[i]!;
      if (i === 0) {
        cum[0] = 0;
      } else {
        const prev = points[i - 1]!;
        cum[i] = cum[i - 1]! + Math.hypot(p.x - prev.x, p.y - prev.y);
      }
      const next = points[i + 1];
      if (next) {
        const dx = next.x - p.x;
        const dy = next.y - p.y;
        if (dx * dx + dy * dy > 0) carried = Math.atan2(dy, dx);
      }
      headings[i] = carried;
    }

    lineVersion++;
    setOffsets();
  }

  /**
   * `ghost.sample_at` — the line's pose at time `t`, clamped at both ends.
   *
   * Linear in the number of points, walked from the start on every call exactly
   * as the Lua does it. The field is at most `MAX_GHOSTS` samples per step
   * against a line of a few hundred points; a cursor would be an optimisation
   * with a wrap bug in it.
   */
  function sampleAt(t: number): { x: number; y: number; head: number } | null {
    if (line.length === 0) return null;
    const first = line[0]!;
    if (t <= first.t) return { x: first.x, y: first.y, head: headings[0]! };
    const lastIndex = line.length - 1;
    const last = line[lastIndex]!;
    if (t >= last.t) return { x: last.x, y: last.y, head: headings[lastIndex]! };

    for (let i = 0; i < lastIndex; i++) {
      const a = line[i]!;
      const b = line[i + 1]!;
      if (t >= a.t && t <= b.t) {
        const span = b.t - a.t;
        const f = span > 0 ? (t - a.t) / span : 0;
        return {
          x: a.x + (b.x - a.x) * f,
          y: a.y + (b.y - a.y) * f,
          // Short way round, like every other heading that crosses this
          // codebase: a plain lerp across the 2pi seam spins a ghost a full
          // revolution between two adjacent points.
          head: angle.lerp(headings[i]!, headings[i + 1]!, f),
        };
      }
    }
    return { x: last.x, y: last.y, head: headings[lastIndex]! };
  }

  /**
   * The line's pose at `phase`, with `flip` added to the heading — 0 for a ghost
   * facing along the line, pi for one running it backwards.
   *
   * Shared by the field and the pace ghost so the lookahead rule is written
   * once: prefer the tangent to a point `HEADING_DT` further along, and fall
   * back to the per-point heading where the line does not actually move there.
   */
  function poseAt(phase: number, flip: number): GhostPose | null {
    const s = sampleAt(phase);
    if (s === null) return null;
    let head = s.head + flip;
    const ahead = sampleAt(wrap(phase + HEADING_DT, period));
    if (ahead !== null) {
      const dx = ahead.x - s.x;
      const dy = ahead.y - s.y;
      // The lookahead is the better tangent where the line actually moves; where
      // it doesn't — a ghost parked where the lap stalled — the per-point heading
      // is all there is, and it is already carried forward from the last real one.
      if (dx * dx + dy * dy > 0.01) head = Math.atan2(dy, dx) + flip;
    }
    return { x: s.x, z: s.y, head: angle.normalize(head) };
  }

  const field: GhostField = {
    get line() {
      return line;
    },
    get lineVersion() {
      return lineVersion;
    },
    get count() {
      // `TUNE.ghosts` is a live slider, and the Lua re-lays the field on every
      // change of it (`endless_dev.lua:593`, the `[` / `]` keys). Checking here
      // rather than pushing from the HUD keeps that a property of the field
      // instead of a wire someone has to remember to connect.
      if (laidFor !== ghostCount()) setOffsets();
      return offsets.length;
    },

    step(dt, x, z) {
      lapT += dt;
      recording.push({ t: lapT, x, y: z });
    },

    pose(i) {
      if (i < 0 || i >= field.count) return null;
      if (taken[i] === true) return null;
      if (period <= 0) return null;
      const offset = offsets[i];
      if (offset === undefined) return null;

      // Wrapping, not retiring: the phase walks the recorded lap at
      // `ghostSpeed` x real time and wraps seamlessly, because a lap is a closed
      // loop. Driven by the *lap* clock rather than session time, so the field
      // re-lays itself at every rollover — and at the default `ghostSpeed` of 0
      // each ghost simply sits on its arc-length offset all lap.
      const moved = lapT * TUNE.ghostSpeed;
      const phase = wrap(TUNE.sameDir ? offset + moved : offset - moved, period);
      // Retrograde ghosts face the way they are *going*, which is backwards
      // along the line, so the heading flips with them.
      return poseAt(phase, TUNE.sameDir ? 0 : Math.PI);
    },

    pacePose() {
      if (!TUNE.paceGhost || period <= 0) return null;
      return poseAt(wrap(lapT, period), 0);
    },

    take(i) {
      taken[i] = true;
    },

    touched(i) {
      return touching[i] === true;
    },

    setTouched(i, value) {
      touching[i] = value;
    },

    promote() {
      // `endless_dev.lua:455`'s `#rec > 1` guard, applied to the downsampled
      // result: a line of one point has no arc length, so it would lay every
      // ghost on the same spot. A lap this short is a restart or a hand-placed
      // car, not a lap.
      const promoted = downsample(recording);
      if (promoted.length < 2) return;
      setLine(promoted);
    },

    rollover() {
      // Deliberately *not* `setOffsets()`: the field is re-laid by `promote()`
      // when the line changes and by the count check otherwise. What resets here
      // is the lap's own state — the clock the phases read, the recording, and
      // the per-ghost flags that make a ghost worth one hit per lap.
      lapT = 0;
      recording = [];
      taken = [];
      touching = [];
    },

    restart() {
      // Back to the seeded reference lap. Run one must have a plausible ghost
      // chain already in place: with telegraphing set to none, a blind first lap
      // is hunting invisible pickups on an unlearned track.
      setLine(track.referenceLap.points);
      field.rollover();
    },
  };

  field.restart();
  return field;
}

/**
 * `reference.lua`'s `downsample` — keep the first point, then any point at least
 * `MIN_SPACING` from the last kept one, then the true last position so the arc
 * length reaches the finish. Each kept point keeps its own timestamp, which is
 * what makes the result a *pace* curve and not just a shape.
 */
export function downsample(recording: readonly LinePoint[]): LinePoint[] {
  const points: LinePoint[] = [];
  let last: LinePoint | undefined;
  for (const s of recording) {
    if (last === undefined) {
      points.push(s);
      last = s;
    } else {
      const dx = s.x - last.x;
      const dy = s.y - last.y;
      if (dx * dx + dy * dy >= MIN_SPACING * MIN_SPACING) {
        points.push(s);
        last = s;
      }
    }
  }
  const fin = recording[recording.length - 1];
  if (fin !== undefined && last !== fin) points.push(fin);
  return points;
}

/** Lua's floor-based `%`: the result carries the sign of `m`, never of `v`. */
function wrap(v: number, m: number): number {
  return v - m * Math.floor(v / m);
}
