/**
 * The harness loop, and the composition root that owns the sim/render split.
 *
 * Fixed 120Hz timestep with an accumulator, interpolated render. This is
 * non-negotiable: the entire output of this prototype is numbers compared
 * between laps, and raw requestAnimationFrame deltas vary with display refresh
 * rate — the same driving would produce different lap times on different
 * machines, and a 144Hz-recorded ghost would replay wrong at 60Hz.
 *
 * The sim never sees wall-clock time. It is stepped by exactly FIXED_DT, or not
 * at all.
 */

import {
  applyUpgrades,
  createCar,
  resetCar,
  stepCar,
  MID_SPEC,
  type Car,
} from "./src/sim/car.js";
import { createKeyboard } from "./src/io/keyboard.js";
import { createScene } from "./src/render/scene.js";
import * as angle from "./src/sim/angle.js";

export const FIXED_HZ = 120;
export const FIXED_DT = 1 / FIXED_HZ;

/**
 * Longest wall-clock gap we will try to catch up on. Beyond this (a backgrounded
 * tab, a breakpoint) we drop the excess rather than stepping thousands of times
 * in one frame and stalling the machine. Dropped time is counted, not hidden —
 * `probe` reports it.
 */
export const MAX_FRAME_SECONDS = 0.25;

export interface LoopStats {
  /** Fixed steps executed since start. */
  steps: number;
  /** Fixed steps executed in the most recent frame. */
  stepsThisFrame: number;
  /** Largest `stepsThisFrame` seen so far. */
  maxStepsInFrame: number;
  /** Simulated seconds: `steps * FIXED_DT`, exactly. */
  simSeconds: number;
  /** Wall-clock seconds since the first frame. */
  wallSeconds: number;
  /** Wall-clock seconds discarded by the MAX_FRAME_SECONDS clamp. */
  droppedSeconds: number;
  /** Rendered frames per second, smoothed. */
  fps: number;
}

export interface LoopHandle {
  stop(): void;
}

export interface LoopSpec {
  /** Advance the sim by exactly FIXED_DT. Called 0..n times per frame. */
  step(dt: number): void;
  /** Draw. `alpha` in [0,1) is how far past the last fixed step we are. */
  render(alpha: number, stats: LoopStats): void;
}

export function startLoop(spec: LoopSpec): LoopHandle {
  let accumulator = 0;
  let previous = performance.now();
  const startedAt = previous;
  let running = true;
  let frameId = 0;

  let steps = 0;
  let maxStepsInFrame = 0;
  let droppedSeconds = 0;
  let fps = 0;

  const frame = (now: number): void => {
    if (!running) return;
    frameId = requestAnimationFrame(frame);

    let frameSeconds = (now - previous) / 1000;
    previous = now;

    if (frameSeconds > MAX_FRAME_SECONDS) {
      droppedSeconds += frameSeconds - MAX_FRAME_SECONDS;
      frameSeconds = MAX_FRAME_SECONDS;
    }

    // Smoothed, and only ever an observation — nothing downstream reads it.
    if (frameSeconds > 0) fps += (1 / frameSeconds - fps) * 0.1;

    accumulator += frameSeconds;
    let stepsThisFrame = 0;
    while (accumulator >= FIXED_DT) {
      spec.step(FIXED_DT);
      accumulator -= FIXED_DT;
      stepsThisFrame++;
      steps++;
    }
    if (stepsThisFrame > maxStepsInFrame) maxStepsInFrame = stepsThisFrame;

    spec.render(accumulator / FIXED_DT, {
      steps,
      stepsThisFrame,
      maxStepsInFrame,
      simSeconds: steps * FIXED_DT,
      wallSeconds: (now - startedAt) / 1000,
      droppedSeconds,
      fps,
    });
  };

  frameId = requestAnimationFrame(frame);

  return {
    stop() {
      running = false;
      cancelAnimationFrame(frameId);
    },
  };
}

// --- composition root ------------------------------------------------------

const scene = createScene(document.body);
const keyboard = createKeyboard();

const car: Car = createCar();
applyUpgrades(car, MID_SPEC);
resetCar(car, 0, 0);

/**
 * Last step's pose, kept so `render` can interpolate across the leftover
 * accumulator. Only these five numbers cross the sim/render seam.
 *
 * `facingAngle` and `velAngle` interpolate through `angle.lerp`, not a plain
 * lerp: both are normalized into `[0, 2pi)` every step, so a kart turning past
 * north would otherwise spin a whole revolution backwards on the wrap frame.
 */
const previous = {
  x: car.x,
  z: car.z,
  facingAngle: car.facingAngle,
  velAngle: car.velAngle,
};

const probe = document.getElementById("probe");
let probeAt = 0;

// Nothing in this prototype persists, so the fastest way to try a tuning change
// is the console: `car.driftDrag = 1.2`. T8 replaces this with real lil-gui
// knobs; until then it beats editing a constant and losing the drive.
(window as unknown as { car: Car }).car = car;

startLoop({
  step(dt) {
    previous.x = car.x;
    previous.z = car.z;
    previous.facingAngle = car.facingAngle;
    previous.velAngle = car.velAngle;
    // No collider: T4 judges the model on an empty plane. T5 passes one here.
    stepCar(car, keyboard.takeStep(), dt);
  },
  render(alpha, stats) {
    scene.draw({
      x: previous.x + (car.x - previous.x) * alpha,
      z: previous.z + (car.z - previous.z) * alpha,
      facingAngle: angle.lerp(previous.facingAngle, car.facingAngle, alpha),
      velAngle: angle.lerp(previous.velAngle, car.velAngle, alpha),
      drifting: car.isDrifting,
    });

    // Timestep proof: sim seconds should track wall seconds minus dropped time,
    // whatever the display refresh rate is. The car lines below it are the only
    // instrument T4 has for telling a bad number from a bad feel.
    if (probe && stats.wallSeconds - probeAt > 0.1) {
      probeAt = stats.wallSeconds;
      const drift = stats.wallSeconds - stats.droppedSeconds - stats.simSeconds;
      const slip = angle.lerp(0, car.velAngle - car.facingAngle, 1);
      probe.textContent = [
        `fixed      ${FIXED_HZ}Hz  (dt ${(FIXED_DT * 1000).toFixed(3)}ms)`,
        `render     ${stats.fps.toFixed(1)} fps`,
        `sim        ${stats.simSeconds.toFixed(2)}s   drift ${(drift * 1000).toFixed(1)}ms`,
        ``,
        `vel        ${car.vel.toFixed(1)} px/s   (top ${car.topVel})`,
        `facing     ${((car.facingAngle * 180) / Math.PI).toFixed(0)}°`,
        `slip       ${((slip * 180) / Math.PI).toFixed(1)}°   ${car.isDrifting ? "DRIFT" : ""}`,
        `drift t    ${car.driftTime.toFixed(2)}s   ${car.boostReady ? "BOOST READY" : ""}`,
        `boosts     ${car.boosts}/${car.maxBoosts}`,
        ``,
        `arrows/AD steer   Z brake   X drift   C boost   R reset`,
      ].join("\n");
    }
  },
});

// Not a game input — an empty plane has no lap line to cross, and a car that has
// wandered off into the grid needs some way back. T9 owns the real reset beat.
window.addEventListener("keydown", (e) => {
  if (e.code === "KeyR") resetCar(car, 0, 0);
});
