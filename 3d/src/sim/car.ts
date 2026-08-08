/**
 * The scalar car model, ported from `car.lua` (T4, issue #5).
 *
 * ## What this is
 *
 * Not a physics kart. One `vel` **scalar** plus three angles:
 *
 * - `facingAngle` — where the kart points.
 * - `velAngle` — where it actually travels. Equal to `facingAngle` except while
 *   drifting or mid-flip.
 * - `driftDir` — which sign of travel the current drift locked in.
 *
 * There is no velocity vector in state, no mass, no lateral force. Speed is a
 * signed scalar along `velAngle`, and every mechanic — throttle, brake, boost,
 * drift scrub — is an addition to that one number. Preserving the *order* of
 * those additions is the whole parity story, so `stepCar` below runs `car.lua`'s
 * update in its original sequence even where a tidier order would read better.
 *
 * ## Coordinate space
 *
 * Source pixels, top-down, exactly as `io/types.ts` documents: `x` runs east,
 * `z` runs south, angle 0 is +x increasing toward +z. `car.lua`'s `y` is this
 * `z` — that rename is the entire 3D port. **Position is the car's top-left
 * corner**, not its center, because `car.lua` tracks the corner of a 16x16 box
 * and the reference lap was captured off it.
 *
 * ## What is deliberately absent
 *
 * - **Walls.** No tile lookup, no `MAX_MOVE_STEP` sweep, no `bounce_x/bounce_y`,
 *   no world-bounds clamp. All of it lives in `sim/collision.ts` (T5) and enters
 *   through the `resolveMove` seam below. Splitting it out is what makes the
 *   feel judgement bisectable: if the kart feels wrong on an empty plane it is
 *   this file, if it only feels wrong once walls exist it is collision.
 * - **Everything drawn or heard.** Headlights, taillights, flames, skid marks,
 *   the engine loop and the squeal (~320 of `car.lua`'s 573 lines) are dropped.
 *   `boostFlameT` survives as *state* only, because `render/kart.ts` will want
 *   it; nothing in `sim/` reads it.
 * - **Progression.** `applyUpgrades` is here, but as a knob, not a ladder.
 */

import * as angle from "./angle.js";
import type { CarInput } from "./input.js";

// --- authored constants, verbatim from car.lua -----------------------------

/** Side of the car's collision box, in source pixels. */
export const CAR_SIZE = 16;
/** Inset used by `collision.ts`'s tile test. Kept next to CAR_SIZE. */
export const CAR_MARGIN = 3;

const ACCEL_BASE = 35;
const ACCEL_STEP = 10;
const TOP_VEL_BASE = 120;
const TOP_VEL_STEP = 50;

/** One manual (BTN3) boost, in px/s along the travel direction. */
const OVERSPEED_IMPULSE = 100;
/** Rate anything above `topVel` bleeds back down, in px/s^2. */
const OVERSPEED_DECAY = 100;
/**
 * Boosts may push `vel` past `topVel`, but never past `topVel + OVERSPEED_MAX`.
 * The hard global cap: `OVERSPEED_DECAY` still bleeds the excess away, this only
 * stops stacked boosts from running off.
 */
const OVERSPEED_MAX = 100;

const BOOST_FLAME_TIME = 0.8;

/**
 * The throttle is always on — BTN1 is the brake, not the gas — so the flip is
 * the only thing that decides which end of the car leads. Double-tapping BTN1
 * inside `FLIP_TAP_WINDOW` spins the car 180 over `FLIP_DURATION` while it keeps
 * sliding along its original line, then swaps gears: forward at v becomes
 * reverse at v in the same travel direction. `gear` is what makes that sticky.
 */
const FLIP_TAP_WINDOW = 0.3;
const FLIP_DURATION = 0.3;

/**
 * Gear the car spawns in. `car.lua` derives this from `track_data.REVERSE_MODE`;
 * the prototype exports no such flag (see `io/types.ts`), and track 3 spawns
 * facing east down the top straight, so forward it is.
 */
const START_GEAR = 1;

// --- state -----------------------------------------------------------------

/**
 * The whole car. Mutated in place by `stepCar` — one allocation for the life of
 * the session, so nothing here churns the GC at 120Hz.
 *
 * The tuning fields (`accel` through `driftDrag`) live on the instance rather
 * than as module constants precisely so T8's knobs can write them live.
 */
export interface Car {
  /** Top-left corner, source pixels, east. */
  x: number;
  /** Top-left corner, source pixels, south. `car.lua`'s `y`. */
  z: number;
  /** Signed scalar speed along `velAngle`, px/s. Negative means reverse. */
  vel: number;

  /** Where the kart points, radians. */
  facingAngle: number;
  /** Where the kart travels, radians. Diverges from facing only in a drift. */
  velAngle: number;

  // tuning — written by applyUpgrades and by T8's knobs
  accel: number;
  deccel: number;
  topVel: number;
  turnRateSlow: number;
  turnRateFast: number;
  turnRefSpeed: number;
  driftTurnRate: number;
  /** Lerp rate of `velAngle` toward the steered target while drifting. */
  driftSlide: number;
  /**
   * Drift scrub is a flat floor plus a speed-proportional term:
   * `driftDeccel + driftDrag * |vel|`, px/s^2. The two ends pull opposite ways —
   * all-flat stalls a slow car dead, all-proportional turns a fast drift into a
   * handbrake while a slow one slides on ice forever — so the dial that matters
   * is where the curve crosses, around 82 px/s at the authored values.
   * `driftDeccel` sits deliberately above max accel so a drift always ends, but
   * from 40 px/s that takes ~2.7s: slow corners roll through rather than stall.
   */
  driftDeccel: number;
  driftDrag: number;
  /** Seconds of drift needed to arm the drift boost. */
  driftThreshold: number;
  /** Impulse the armed drift boost pays out, px/s. */
  boostValue: number;
  /** Seconds the drift-boost readout lingers. Cosmetic; nothing gates on it. */
  boostLength: number;

  // unlocks
  driftEnabled: boolean;
  driftBoostEnabled: boolean;
  reverseEnabled: boolean;
  maxBoosts: number;

  // live drift/boost state
  isDrifting: boolean;
  driftTime: number;
  /** Sign of travel the active drift locked in. Taken from `gear`, not `vel`. */
  driftDir: number;
  boostReady: boolean;
  boostTimeRemaining: number;
  boosts: number;
  /** Seconds of exhaust flame left. Written here, read only by `render/`. */
  boostFlameT: number;

  // gear / flip
  /** +1 nose-first, -1 trunk-first. Only a completed flip changes it. */
  gear: number;
  flipTapT: number;
  flipT: number;
  flipFrom: number;
  flipDir: number;
}

export function createCar(): Car {
  return {
    x: 0,
    z: 0,
    vel: 0,
    facingAngle: 0,
    velAngle: 0,

    accel: ACCEL_BASE,
    deccel: 150,
    topVel: TOP_VEL_BASE,
    turnRateSlow: 2.0,
    turnRateFast: 1.0,
    turnRefSpeed: TOP_VEL_BASE,
    driftTurnRate: 3.2,
    driftSlide: Math.PI / 8,
    driftDeccel: 80,
    driftDrag: 0.7,
    driftThreshold: 0.5,
    boostValue: 200,
    boostLength: 1.2,

    driftEnabled: false,
    driftBoostEnabled: false,
    reverseEnabled: false,
    maxBoosts: 0,

    isDrifting: false,
    driftTime: 0,
    driftDir: 0,
    boostReady: false,
    boostTimeRemaining: 0,
    boosts: 0,
    boostFlameT: 0,

    gear: START_GEAR,
    flipTapT: 0,
    flipT: 0,
    flipFrom: 0,
    flipDir: 1,
  };
}

/** `car.reset` — back to a spawn pose. Position is a top-left corner. */
export function resetCar(car: Car, spawnX: number, spawnZ: number, facing = 0): void {
  car.x = spawnX;
  car.z = spawnZ;
  car.vel = 0;
  car.facingAngle = facing;
  car.velAngle = facing;
  car.isDrifting = false;
  car.driftTime = 0;
  car.driftDir = 0;
  car.gear = START_GEAR;
  car.flipTapT = 0;
  car.flipT = 0;
  car.boostReady = false;
  car.boostTimeRemaining = 0;
  car.boosts = car.maxBoosts;
  car.boostFlameT = 0;
}

/**
 * The upgrade ladder, flattened to a knob. Levels in, tuning out — no cost, no
 * persistence, no rebirth. `endless_dev.lua:622` seeds a mid-spec car this way
 * and that is all the prototype wants from progression.
 */
export interface Upgrades {
  /** Each level adds `ACCEL_STEP` (10) px/s^2 over the base 35. */
  accelLevel: number;
  /** Each level adds `TOP_VEL_STEP` (50) px/s over the base 120. */
  topSpeedLevel: number;
  driftEnabled: boolean;
  driftBoostEnabled: boolean;
  /** Stored manual boosts, refilled on reset. */
  boostRanks: number;
  reverseEnabled: boolean;
}

/**
 * The seed the prototype boots with — `endless_dev.lua`'s mid-spec car. A base
 * car makes every `$/sec` reading a speed test rather than a mechanic test.
 *
 * Two knowing departures from `endless_dev.lua:622`, both flagged on issue #5:
 *
 * - **`topSpeedLevel: 2`, `boostRanks: 2`** — the call there passes `1` and `0`
 *   while its own comment above it says "top speed 2 ... boost 2". Issue #5
 *   restates the comment, so the comment wins here; `boostRanks: 0` would leave
 *   the manual boost untestable in the one ticket that exists to judge feel.
 * - **`reverseEnabled: false`** — `endless_dev.lua` passes `true`, but
 *   `io/types.ts` (T2, settled) records that this prototype has no flip/reverse
 *   move, which is why track 3's gates are excluded from the export. The flip is
 *   ported below regardless: `gear` is load-bearing for the always-on throttle
 *   even when it never changes, and flipping it back on is one boolean.
 */
export const MID_SPEC: Upgrades = {
  accelLevel: 2,
  topSpeedLevel: 2,
  driftEnabled: true,
  driftBoostEnabled: true,
  boostRanks: 2,
  reverseEnabled: false,
};

export function applyUpgrades(car: Car, u: Upgrades): void {
  car.accel = ACCEL_BASE + u.accelLevel * ACCEL_STEP;
  car.topVel = TOP_VEL_BASE + u.topSpeedLevel * TOP_VEL_STEP;
  car.driftEnabled = u.driftEnabled;
  car.driftBoostEnabled = u.driftBoostEnabled;
  car.maxBoosts = u.boostRanks;
  car.reverseEnabled = u.reverseEnabled;
}

/**
 * Adds `impulse` px/s along the car's current travel direction (its drift
 * direction while drifting), clamped to the overspeed ceiling so stacked boosts
 * cannot run away. This is the shared rule; T12's pickup pads and ghost hits
 * call it, and the manual BTN3 boost inlines it against the drift state
 * computed fresh this step.
 */
export function applyBoost(car: Car, impulse: number): void {
  const dir = car.isDrifting ? car.driftDir : car.gear;
  const maxVel = car.topVel + OVERSPEED_MAX;
  car.vel = clamp(car.vel + dir * impulse, -maxVel, maxVel);
  car.boostFlameT = BOOST_FLAME_TIME;
}

// --- the step --------------------------------------------------------------

/**
 * The seam T5 inserts at. Given the motion the car wants this step, report the
 * motion it actually gets.
 *
 * `car.lua` interleaves the tile sweep with the wall response inside `update`;
 * pulling it behind a callback keeps `sim/car.ts` free of the map without
 * changing where in the sequence collision happens. Absent a collider the car
 * moves freely, which is exactly the empty plane this ticket judges on.
 *
 * Returned position is absolute, not a delta, because a swept collider ends up
 * somewhere the caller cannot recompute from `dx`/`dz`.
 */
export type ResolveMove = (
  car: Car,
  dx: number,
  dz: number,
  dt: number,
) => { x: number; z: number };

const freeMove: ResolveMove = (car, dx, dz) => ({ x: car.x + dx, z: car.z + dz });

/**
 * One fixed step. Mutates `car`.
 *
 * The sequence is `car.lua`'s, and the order is the model:
 *
 * 1. flip tap window, then the flip spin (which can end and swap gear),
 * 2. resolve whether this step is a drift, and lock `driftDir` if it just began,
 * 3. steer `velAngle` — lerped toward the steered target in a drift, pinned to
 *    the pre-flip line mid-flip, else glued to `facingAngle`,
 * 4. **move**, using the `velAngle` and `vel` from *before* this step's throttle,
 * 5. manual boost, then throttle/brake/overspeed as one if-chain,
 * 6. drift scrub, with the sign lock,
 * 7. steer `facingAngle` — after the move, so the kart turns into the next step,
 * 8. arm or cash the drift boost.
 *
 * Steps 4 and 7 in that order are why the model feels like it has weight: the
 * car travels on last step's heading and turns afterwards, which is a one-step
 * lag between wheel and body at every speed.
 */
export function stepCar(
  car: Car,
  input: CarInput,
  dt: number,
  resolveMove: ResolveMove = freeMove,
): void {
  const holdingLeft = input.left;
  const holdingRight = input.right;

  const driftHeld = car.driftEnabled && input.drift;
  // Grabbing the handbrake mid-spin snaps the flip to finished rather than
  // being swallowed by it, so the drift starts in the orientation and gear the
  // player is already steering for. Read before this step's tap, so a flip begun
  // while the handbrake is down still spins at normal speed.
  const cutFlip = driftHeld && car.flipT > 0;

  if (car.flipTapT > 0) car.flipTapT = Math.max(0, car.flipTapT - dt);
  if (input.brakePressed && car.flipT <= 0 && car.reverseEnabled) {
    if (car.flipTapT > 0) {
      // Second tap inside the window: spin toward whichever way the player is
      // steering (defaults right).
      car.flipT = FLIP_DURATION;
      car.flipFrom = car.facingAngle;
      car.flipDir = holdingLeft ? -1 : 1;
      car.flipTapT = 0;
    } else {
      car.flipTapT = FLIP_TAP_WINDOW;
    }
  }

  if (car.flipT > 0) {
    car.flipT = cutFlip ? 0 : Math.max(0, car.flipT - dt);
    const progress = 1 - car.flipT / FLIP_DURATION;
    car.facingAngle = angle.normalize(car.flipFrom + car.flipDir * progress * Math.PI);
    if (car.flipT <= 0) {
      // Spin finished: swap gears. Travel continues in the original direction at
      // the same speed, now with the other end of the car leading, and the
      // throttle keeps pushing that way until the next flip.
      car.vel = -car.vel;
      car.gear = -car.gear;
      // Negating vel turns the pre-flip line into the same line read from the
      // new nose, so velAngle has to come along. The non-drift path below
      // reassigns it anyway; a drift starting this step lerps from it, and would
      // otherwise swing a full 180 off the stale pre-flip value.
      car.velAngle = car.facingAngle;
    }
  }
  const flipping = car.flipT > 0;
  // The tap that starts a flip is a BTN1 press like any other, so brakes are off
  // for the whole spin: the car carries its line through the 180 instead of the
  // second tap doubling as a stab of brake.
  const braking = input.brake && !flipping;

  // A spin already underway was cut short above, so the only flip still running
  // here is one started this step; that one runs its course.
  const isDrifting = driftHeld && !flipping;
  // A drift locks in the direction of travel it started with; vel may bleed to 0
  // during the drift but never crosses to the other sign. Taken from the gear
  // rather than sign(vel) so a drift begun from a standstill still slides the
  // way the car is about to pull away.
  if (isDrifting && !car.isDrifting) car.driftDir = car.gear;

  let targetVelAngle = car.facingAngle;
  if (isDrifting && (holdingLeft || holdingRight)) {
    const dir = holdingLeft ? -1 : 1;
    // The slide angle scales with speed: a fast drift hangs the tail out wide,
    // a slow one barely steps out. 0.005 rad per px/s is the authored number.
    targetVelAngle = car.facingAngle + dir * 0.005 * Math.abs(car.vel);
  }

  if (isDrifting) {
    car.velAngle = angle.lerp(car.velAngle, targetVelAngle, car.driftSlide * dt);
  } else if (flipping) {
    // Mid-spin the car keeps sliding along its pre-flip line; the 180 is a gear
    // change, not a U-turn.
    car.velAngle = car.flipFrom;
  } else {
    car.velAngle = car.facingAngle;
  }

  // A drift travels 10% further than its scalar speed says — the tail slinging
  // round adds real ground speed, which is what makes drifting worth doing at
  // all against the scrub below.
  const driftFactor = isDrifting ? 1.1 : 1;
  const step = driftFactor * car.vel * dt;
  const moveX = Math.cos(car.velAngle) * step;
  const moveZ = Math.sin(car.velAngle) * step;

  const moved = resolveMove(car, moveX, moveZ, dt);
  car.x = moved.x;
  car.z = moved.z;

  const effectiveTopVel = car.topVel;
  const maxVel = effectiveTopVel + OVERSPEED_MAX;
  const minVel = car.reverseEnabled ? -effectiveTopVel : 0;

  if (input.boostPressed && car.boosts > 0) {
    const boostDir = isDrifting ? car.driftDir : car.gear;
    car.vel = clamp(car.vel + boostDir * OVERSPEED_IMPULSE, -maxVel, maxVel);
    car.boosts -= 1;
    car.boostFlameT = BOOST_FLAME_TIME;
  }

  // The throttle is always on, pushing toward top speed in the current gear — so
  // reverse accelerates backwards exactly the way forward accelerates forwards.
  // `deccel` is the brake rate, and it only ever bleeds toward a standstill: the
  // brake cannot drag the car through zero into the other gear, because a flip
  // is the only thing that changes gear. Stopping dead and letting go therefore
  // pulls away the same way the car was already pointed.
  if (car.vel > effectiveTopVel) {
    car.vel = Math.max(effectiveTopVel, car.vel - OVERSPEED_DECAY * dt);
  } else if (car.vel < minVel) {
    car.vel = Math.min(minVel, car.vel + OVERSPEED_DECAY * dt);
  } else if (braking) {
    car.vel = bleedVel(car.vel, car.deccel * dt);
  } else {
    car.vel = clamp(car.vel + car.gear * car.accel * dt, minVel, effectiveTopVel);
  }

  if (isDrifting) {
    car.vel = bleedVel(car.vel, (car.driftDeccel + Math.abs(car.vel) * car.driftDrag) * dt);
    // Belt and braces on the drift's sign lock. driftDir comes from the gear and
    // the throttle only ever pushes along the gear, so nothing above should
    // cross zero on its own; this pins a scrubbed-out drift at a standstill if
    // some later impulse ever tries to.
    car.vel = car.driftDir < 0 ? Math.min(0, car.vel) : Math.max(0, car.vel);
  }

  if (car.boostFlameT > 0) car.boostFlameT = Math.max(0, car.boostFlameT - dt);

  if ((holdingLeft || holdingRight) && !flipping) {
    const dir = holdingLeft ? -1 : 1;
    let rate: number;
    if (isDrifting) {
      rate = car.driftTurnRate;
    } else {
      // Turn rate falls off with speed, linearly, to `turnRefSpeed` and no
      // further: a parked car spins on the spot, a flat-out one barely arcs.
      const t = clamp(Math.abs(car.vel) / car.turnRefSpeed, 0, 1);
      rate = car.turnRateSlow + (car.turnRateFast - car.turnRateSlow) * t;
    }
    car.facingAngle = angle.normalize(car.facingAngle + dir * rate * dt);
  }

  if (isDrifting) {
    car.isDrifting = true;
    car.driftTime += dt;
    if (car.driftTime >= car.driftThreshold && !car.boostReady && car.driftBoostEnabled) {
      car.boostReady = true;
    }
  } else {
    if (car.boostReady) {
      // Cashed on *release*, and capped at topVel rather than the overspeed
      // ceiling: the drift boost restores the speed the scrub cost, it does not
      // stack past flat-out. Note it lights no flame — `car.lua` only sounds the
      // sfx here, unlike the manual boost and `applyBoost`.
      car.boostTimeRemaining = car.boostLength;
      car.vel =
        car.driftDir < 0
          ? Math.max(car.vel - car.boostValue, -car.topVel)
          : Math.min(car.vel + car.boostValue, car.topVel);
      car.boostReady = false;
    }
    car.isDrifting = false;
    car.driftTime = 0;
  }

  if (car.boostTimeRemaining > 0) car.boostTimeRemaining -= dt;
}

// --- small helpers ---------------------------------------------------------

function clamp(v: number, lo: number, hi: number): number {
  return v < lo ? lo : v > hi ? hi : v;
}

/**
 * Reduces `v` toward 0 by `amount`, never crossing zero. `car.lua`'s local
 * `bleed_vel`, exported because the wall response in `sim/collision.ts` is its
 * other caller there and charges speed by the same rule.
 */
export function bleedVel(v: number, amount: number): number {
  return v < 0 ? Math.min(0, v + amount) : Math.max(0, v - amount);
}
