/**
 * Tile collision and wall bounce, ported from `car.lua` (T5, issue #6).
 *
 * This is the other half of the move `sim/car.ts` deliberately does not do. T4
 * left a `ResolveMove` seam at exactly the point `car.lua` runs its sweep —
 * after `velAngle` is settled, *before* this step's throttle — and this file
 * fills it. Nothing here is new: the sweep, the per-axis slide, the impact
 * response and the bounce decay are transcribed from `car.lua:274-340` in that
 * order, because the order is the wall feel.
 *
 * ## Why the sweep exists
 *
 * A boosted car at the `topVel + OVERSPEED_MAX` ceiling (320 px/s) covers 2.7px
 * per 120Hz step, which one dt spike or one future upgrade turns into a jump
 * clean over a 16px wall tile. Movement is therefore chopped into substeps of at
 * most `MAX_MOVE_STEP` pixels and each one tested, so the samples can never
 * straddle a tile. It is O(distance), not O(map).
 *
 * ## Why the response is a *bounce accumulator* and not a reflected velocity
 *
 * The model has no velocity vector to reflect — `vel` is a signed scalar along
 * `velAngle`, and a wall hit must not rotate the car. So the rebound lives
 * outside the model, as `bounceX`/`bounceZ` in px/s, added to the requested
 * motion and decayed at `BOUNCE_DECAY` every step. The car keeps pointing (and
 * accelerating) into the wall; the bounce just carries it away for a moment.
 *
 * The two-band response is what lets a car rest against a wall without jitter:
 *
 * - **At or above `MIN_BOUNCE_VEL`** of blocked motion, a real hit — the bounce
 *   is set to `-(1 + WALL_RESTITUTION)` times the blocked component (cancel,
 *   then rebound), and `vel` pays `impact * WALL_LOSS_FACTOR`.
 * - **Below it**, a scrape — no bounce at all, just `WALL_DECEL` scaled by how
 *   head-on the contact was. A shallow graze down a wall stays nearly free;
 *   sitting flush costs the full rate and goes nowhere.
 *
 * `WALL_RESTITUTION` is 0.001, which is to say: this game does not bounce the
 * car off walls, it stops it. The `-(1 + r)` shape is still what cancels the
 * frame's motion into the wall, so it is not dead code — the rebound term is
 * just deliberately homeopathic.
 *
 * ## What is *not* here
 *
 * Wall **height** and how a barrier is painted are `render/`'s business (T6).
 * Collision is a flat 2D tile test at the car's four inset corners, exactly as
 * in the 2D game; the rendered curb could be a mile high and this file would not
 * know.
 */

import { CAR_MARGIN, CAR_SIZE, bleedVel, type Car, type ResolveMove } from "./car.js";
import { DRIVABLE_TILES, type TrackExport } from "../io/types.js";
import { worldSize } from "../io/trackData.js";

// --- authored constants, verbatim from car.lua:22-30 -----------------------

/**
 * Contact at or above this much blocked motion (px/s) is a bounce; below it is
 * a scrape. The threshold is what keeps a car parked against a wall quiet.
 */
const MIN_BOUNCE_VEL = 40;
/** Rebound fraction of the blocked component. Effectively zero, by design. */
const WALL_RESTITUTION = 0.001;
/** Fraction of a real impact charged against `vel`, in px/s per px/s. */
const WALL_LOSS_FACTOR = 0.8;
/** Scrape bleed rate, px/s^2, scaled by how head-on the contact is. */
const WALL_DECEL = 500;
/** Rate the bounce accumulator decays back to zero, px/s^2. */
const BOUNCE_DECAY = 550;
/**
 * Longest distance, in source pixels, any one collision substep may cover. Well
 * under `tileSize` (16), so the sweep cannot skip a tile.
 */
const MAX_MOVE_STEP = 4;

// --- the tile test ---------------------------------------------------------

/**
 * `road.get_tile` — flat row-major lookup, out of bounds reported as `WALL`.
 *
 * Out-of-bounds reading as a blocking tile rather than as an error is
 * load-bearing: the bounds clamp in the sweep keeps the car's *corner* inside
 * the world, but the four sample points are offsets from it, so the far corners
 * legitimately probe past the edge on the last pixel.
 */
function tileAt(track: TrackExport, x: number, z: number): number {
  const col = Math.floor(x / track.tileSize);
  const row = Math.floor(z / track.tileSize);
  const { width, height } = track.map;
  if (col < 0 || col >= width || row < 0 || row >= height) return 0;
  return track.map.tiles[row * width + col]!;
}

/**
 * `road.on_road` — the car's box is on the road when all four of its inset
 * corners are on drivable tiles.
 *
 * The inset is `CAR_MARGIN` (3) on each side of the 16px box, sampling a 10px
 * square. That slack is generous on purpose: it lets the car clip the inside of
 * a corner slightly rather than catching on it, and it is why the 2D game's
 * apexes are takeable at all. Four point samples also mean a barrier thinner
 * than 10px could in principle sit between them — track 3 has none, and the
 * export's blocking tiles are whole 16px cells.
 *
 * `x`/`z` are the box's **top-left corner**, as everywhere else in `sim/`.
 */
export function onRoad(track: TrackExport, x: number, z: number): boolean {
  const inner = CAR_SIZE - CAR_MARGIN - 1;
  return (
    DRIVABLE_TILES.has(tileAt(track, x + CAR_MARGIN, z + CAR_MARGIN)) &&
    DRIVABLE_TILES.has(tileAt(track, x + inner, z + CAR_MARGIN)) &&
    DRIVABLE_TILES.has(tileAt(track, x + CAR_MARGIN, z + inner)) &&
    DRIVABLE_TILES.has(tileAt(track, x + inner, z + inner))
  );
}

// --- the collider ----------------------------------------------------------

/**
 * A collider bound to one track and one car.
 *
 * Bound to one car because the bounce accumulator is per-car state that `Car`
 * itself does not carry — `car.lua` keeps `bounce_x`/`bounce_y` on the car
 * table, but adding them to `Car` would put wall state in the file whose whole
 * point is that it has none. One collider per car, made where the car is made.
 * (Ghosts are replayed poses, not simulated cars; nothing else needs one.)
 */
export interface Collider {
  /** Pass this to `stepCar`. */
  readonly resolveMove: ResolveMove;
  /** Live bounce velocity, px/s — for the debug readout only. */
  readonly bounceX: number;
  readonly bounceZ: number;
  /** True if the most recent step touched a wall. Debug readout only. */
  readonly touching: boolean;
  /** Clear the bounce. Call alongside `resetCar`. */
  reset(): void;
}

export function createCollider(track: TrackExport): Collider {
  const world = worldSize(track);
  const maxX = world.w - CAR_SIZE;
  const maxZ = world.h - CAR_SIZE;

  let bounceX = 0;
  let bounceZ = 0;
  let touching = false;

  const resolveMove: ResolveMove = (car: Car, dx: number, dz: number, dt: number) => {
    // The bounce rides along with the requested motion rather than being applied
    // separately, so it is swept and blocked by the same test — a car rebounding
    // into a facing wall cannot be pushed through it.
    const moveX = dx + bounceX * dt;
    const moveZ = dz + bounceZ * dt;

    const maxAxis = Math.max(Math.abs(moveX), Math.abs(moveZ));
    const steps = Math.max(1, Math.ceil(maxAxis / MAX_MOVE_STEP));
    const stepX = moveX / steps;
    const stepZ = moveZ / steps;

    let x = car.x;
    let z = car.z;
    let hitX = false;
    let hitZ = false;

    for (let i = 0; i < steps; i++) {
      const newX = clamp(x + stepX, 0, maxX);
      const newZ = clamp(z + stepZ, 0, maxZ);
      if (onRoad(track, newX, newZ)) {
        x = newX;
        z = newZ;
      } else if (onRoad(track, newX, z)) {
        // Free along x, blocked along z: slide down the wall. This per-axis
        // fallback is why a glancing hit does not stop the car dead, and it is
        // the whole reason walls are drivable-against rather than sticky.
        x = newX;
        hitZ = true;
      } else if (onRoad(track, x, newZ)) {
        z = newZ;
        hitX = true;
      } else {
        // Cornered: neither axis is free, so the rest of the sweep cannot go
        // anywhere either.
        hitX = true;
        hitZ = true;
        break;
      }
    }

    touching = hitX || hitZ;

    if (touching && dt > 0) {
      // Impact is the part of this step's motion the wall blocked. It scales
      // both the rebound and the speed cost, so a shallow scrape stays nearly
      // free while a square hit costs real speed.
      const vx = moveX / dt;
      const vz = moveZ / dt;
      const impactX = hitX ? vx : 0;
      const impactZ = hitZ ? vz : 0;
      const impact = Math.hypot(impactX, impactZ);
      if (impact >= MIN_BOUNCE_VEL) {
        // -(1 + r) first cancels the motion into the wall, then adds the
        // rebound, so the car leaves at WALL_RESTITUTION times its impact speed
        // even though `vel` keeps pointing at the wall.
        if (hitX) bounceX = -(1 + WALL_RESTITUTION) * vx;
        if (hitZ) bounceZ = -(1 + WALL_RESTITUTION) * vz;
        car.vel = bleedVel(car.vel, impact * WALL_LOSS_FACTOR);
      } else {
        const speed = Math.hypot(vx, vz);
        const frac = speed > 0 ? impact / speed : 0;
        car.vel = bleedVel(car.vel, WALL_DECEL * frac * dt);
      }
    }

    // Decayed as a vector so a diagonal bounce fades at the same rate as an
    // axial one, and clamped at zero rather than allowed to flip sign.
    const bounceMag = Math.hypot(bounceX, bounceZ);
    if (bounceMag > 0) {
      const scale = Math.max(0, bounceMag - BOUNCE_DECAY * dt) / bounceMag;
      bounceX *= scale;
      bounceZ *= scale;
    }

    return { x, z };
  };

  return {
    resolveMove,
    get bounceX() {
      return bounceX;
    },
    get bounceZ() {
      return bounceZ;
    },
    get touching() {
      return touching;
    },
    reset() {
      bounceX = 0;
      bounceZ = 0;
      touching = false;
    },
  };
}

function clamp(v: number, lo: number, hi: number): number {
  return v < lo ? lo : v > hi ? hi : v;
}
