/**
 * The chase camera (T7, issue #8).
 *
 * Full chase cam behind the kart, Diddy Kong Racing-faithful. It replaces the
 * fixed-orientation overhead follow cam `scene.ts` carried through T4-T6, which
 * existed so the car port could be judged in the same view as the 2D game.
 *
 * ## What the camera is anchored to
 *
 * The kart points one way and travels another — that gap *is* the drift model,
 * and it is the most heavily tuned thing in `car.lua`. So the anchor is neither
 * heading on its own:
 *
 * - Locked to `facingAngle`, a drift swings the camera into the corner while
 *   the kart leaves it sideways, and the exit goes off-screen exactly when you
 *   need to see it.
 * - Locked to `velAngle`, the camera is correct but the *entry* to a drift is a
 *   step change in travel direction, so the view snaps.
 *
 * The anchor is therefore a **blend toward `velAngle`** (`knobs.velBlend`, 0 =
 * pure facing, 1 = pure travel), and the camera is dragged toward that anchor by
 * a **damped spring** (`knobs.stiffness`, `knobs.damping`) rather than snapped
 * to it. Outside a drift the two headings agree and the blend does nothing; it
 * only has an opinion when the kart is sideways, which is the whole point.
 *
 * Both are knobs because neither is derivable — they are feel, tuned live. T8
 * puts them behind lil-gui; until then they are the mutable `knobs` object,
 * exposed on `window.cam` by `loop.ts`.
 *
 * ## Why it is stepped, not lerped per frame
 *
 * `follow` runs in the loop's **fixed** step phase, at `FIXED_DT`, alongside the
 * sim. A spring integrated against raw frame deltas is a different spring at
 * 60Hz and 144Hz — the same tuning would read as two different cameras on two
 * machines, and this ticket is decided by feel, so that is disqualifying. The
 * camera reads sim state and writes only its own object; nothing about it feeds
 * back into the sim, so the fixed cadence costs nothing.
 *
 * The kart is still drawn interpolated. The camera trails by up to one 8.3ms
 * step, which is well inside the spring's own lag.
 */

import * as THREE from "three";
import * as angle from "../sim/angle.js";
import { type KartPose } from "./kart.js";

/**
 * Live camera tuning. Mutable on purpose: every field is a feel judgement, and
 * the fastest way to make one is to drive with the console open.
 */
export interface ChaseKnobs {
  /**
   * How far the anchor heading sits toward `velAngle` (1) rather than
   * `facingAngle` (0). Only bites during a drift, when the two disagree.
   */
  velBlend: number;
  /** Spring constant pulling the camera heading onto the anchor. Higher = tighter. */
  stiffness: number;
  /**
   * Damping ratio. 1 is critically damped — the fastest approach with no
   * overshoot. Below 1 the camera swings past the anchor and settles back,
   * which reads as weight; above 1 it crawls in.
   */
  damping: number;
  /** Distance the camera trails behind the anchor heading, in source pixels. */
  distance: number;
  /** Extra trail distance at `topVel`, ramped by speed. Widens the view at pace. */
  speedPull: number;
  /**
   * Time constant, seconds, on the speed the dolly reads. Raw `vel` changes on
   * every throttle tap and every wall scrape, and `speedPull` turns each of
   * those into a shove along the view axis — the one direction the eye reads as
   * self-motion rather than as the world moving. Lagging the input decouples the
   * dolly from the twitch without touching how far it eventually travels.
   */
  pullLag: number;
  /** Camera height above the road, in source pixels. */
  height: number;
  /** How far ahead of the kart the camera looks, along the anchor heading. */
  lookAhead: number;
  /** Height of the look-at point. Above 0 the horizon sits lower in frame. */
  lookHeight: number;
  /** Vertical field of view, degrees. */
  fov: number;
  /**
   * Speed at which the travel heading is trusted completely. Below it the blend
   * fades back toward `facingAngle`: a near-stationary kart's `velAngle` is a
   * leftover, and letting the camera chase it makes a standstill jitter.
   */
  velTrustSpeed: number;
}

/**
 * Tuned soft rather than tight. Every default here trades response for comfort:
 * a chase cam that corrects fast is *reading* as the world being whipped around
 * the player, and the sim never needs the camera to be exact — it only needs the
 * road ahead in frame. See the individual fields for what each one was traded
 * against; `DEFAULT_KNOBS.stiffness = 40` and `fov = 70` are the previous, snappy
 * values if a tighter feel is ever wanted back.
 */
export const DEFAULT_KNOBS: ChaseKnobs = {
  velBlend: 0,
  stiffness: 8,
  damping: 1.15,
  distance: 10,
  speedPull: 10,
  pullLag: 0.5,
  height: 30,
  lookAhead: 10,
  lookHeight: 20,
  fov: 80,
  velTrustSpeed: 300,
};

/** What the camera needs beyond a pose: how fast, to fade the blend in. */
export interface ChasePose extends KartPose {
  /** Signed travel speed, px/s — `car.vel`. */
  speed: number;
  /** Top speed for the current spec, px/s, so `speedPull` has a scale. */
  topSpeed: number;
}

export interface ChaseCamera {
  readonly camera: THREE.PerspectiveCamera;
  readonly knobs: ChaseKnobs;
  /** Advance the spring by one fixed step and place the camera. */
  follow(pose: ChasePose, dt: number): void;
  /** Drop the spring and put the camera straight behind the pose. For spawn / reset. */
  snap(pose: ChasePose): void;
  setAspect(aspect: number): void;
}

/**
 * The anchor: `facingAngle` blended toward `velAngle`, the short way round, with
 * the blend faded out at low speed. Not a plain lerp — headings live in
 * `[0, 2pi)` and a kart crossing north would otherwise take the long way.
 */
function anchorHeading(pose: ChasePose, knobs: ChaseKnobs): number {
  const trust = Math.min(
    1,
    Math.abs(pose.speed) / Math.max(1, knobs.velTrustSpeed),
  );
  // Travelling backwards means the kart's *travel* is the reverse of velAngle.
  // MID_SPEC has no reverse, so this only fires if a spec re-enables it.
  const travel = pose.speed < 0 ? pose.velAngle + Math.PI : pose.velAngle;
  return angle.lerp(pose.facingAngle, travel, knobs.velBlend * trust);
}

/** The kart's speed as a 0..1 fraction of its spec's top speed. */
function speedT(pose: ChasePose): number {
  return Math.min(1, Math.abs(pose.speed) / Math.max(1, pose.topSpeed));
}

export function createChaseCamera(
  knobs: ChaseKnobs = { ...DEFAULT_KNOBS },
): ChaseCamera {
  const camera = new THREE.PerspectiveCamera(knobs.fov, 1, 1, 4000);
  let fovApplied = knobs.fov;

  /** Where the camera is looking now, and how fast that heading is turning. */
  let heading = 0;
  let headingVel = 0;
  /** The lagged 0..1 speed the dolly reads, rather than the kart's own. */
  let pull = 0;

  const place = (pose: ChasePose): void => {
    // The sim tracks the collision box's top-left corner; frame the middle.
    const cx = pose.x + 8;
    const cz = pose.z + 8;
    const dirX = Math.cos(heading);
    const dirZ = Math.sin(heading);

    const back = knobs.distance + knobs.speedPull * pull;

    camera.position.set(cx - dirX * back, knobs.height, cz - dirZ * back);
    camera.lookAt(
      cx + dirX * knobs.lookAhead,
      knobs.lookHeight,
      cz + dirZ * knobs.lookAhead,
    );

    if (knobs.fov !== fovApplied) {
      fovApplied = knobs.fov;
      camera.fov = knobs.fov;
      camera.updateProjectionMatrix();
    }
  };

  return {
    camera,
    knobs,

    follow(pose, dt) {
      // Exponential approach on the dolly input, on the same fixed step as the
      // spring and for the same reason. Clamped so a pullLag under one step
      // degrades to "no lag" rather than to an oscillation.
      pull +=
        (speedT(pose) - pull) * Math.min(1, dt / Math.max(dt, knobs.pullLag));

      const target = anchorHeading(pose, knobs);
      // The wrapped error, via the same short-way rule the sim uses: lerping all
      // the way to the target and subtracting is exactly the signed difference.
      const error = angle.lerp(heading, target, 1) - heading;

      // Semi-implicit Euler on a damped spring: a = k*e - c*v, with the damping
      // coefficient derived from the ratio so `stiffness` can be retuned without
      // the camera silently becoming underdamped.
      const c = 2 * knobs.damping * Math.sqrt(knobs.stiffness);
      headingVel += (knobs.stiffness * error - c * headingVel) * dt;
      heading = angle.normalize(heading + headingVel * dt);

      place(pose);
    },

    snap(pose) {
      heading = anchorHeading(pose, knobs);
      headingVel = 0;
      pull = speedT(pose);
      place(pose);
    },

    setAspect(aspect) {
      camera.aspect = aspect;
      camera.updateProjectionMatrix();
    },
  };
}
