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
import { createCollider } from "./src/sim/collision.js";
import { createLedger } from "./src/sim/cash.js";
import { createLap } from "./src/sim/lap.js";
import { TUNE } from "./src/sim/tune.js";
import { createKeyboard } from "./src/io/keyboard.js";
import { track3 } from "./src/io/trackData.js";
import { createScene } from "./src/render/scene.js";
import { createHud } from "./src/hud/hud.js";
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

const scene = createScene(document.body, track3);
const keyboard = createKeyboard();

/** The authored spawn pose, in source pixels — a top-left corner, as always. */
const spawn = {
  x: track3.spawn.col * track3.tileSize,
  z: track3.spawn.row * track3.tileSize,
  facing: track3.spawn.facing,
};

const car: Car = createCar();
applyUpgrades(car, MID_SPEC);
// One collider per car: it owns the bounce accumulator `Car` deliberately does
// not carry.
const collider = createCollider(track3);
resetCar(car, spawn.x, spawn.z, spawn.facing);

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

/**
 * Collapse the interpolation window onto the car's current pose.
 *
 * Needed wherever the car *teleports* — a grid start, a restart. Interpolation
 * assumes `previous` is one fixed step behind; across a teleport it is half a
 * track away, and the kart would be drawn flying to the line rather than
 * appearing on it.
 */
function syncPrevious(): void {
  previous.x = car.x;
  previous.z = car.z;
  previous.facingAngle = car.facingAngle;
  previous.velAngle = car.velAngle;
}

/**
 * The pose the chase camera follows: the *unstretched* sim pose, since the
 * camera is stepped on the fixed timestep rather than per rendered frame.
 */
const chasePose = () => ({
  x: car.x,
  z: car.z,
  facingAngle: car.facingAngle,
  velAngle: car.velAngle,
  drifting: car.isDrifting,
  speed: car.vel,
  topSpeed: car.topVel,
});

// Start behind the kart rather than springing in from heading 0 on the first
// step, which would swing the whole track past the camera at the green light.
scene.camera.snap(chasePose());

const probe = document.getElementById("probe");
let probeAt = 0;

/** The money. Checkpoints pay into it; coins and ghost hits are T12. */
const ledger = createLedger();

/**
 * The lap: checkpoint order, the `$/sec` promotion decision, and the grid-start
 * beat. `ghosts` is left out until T10 — with no field to promote into, laps
 * still run, pay and compare rates; they just have no line to install.
 */
const lap = createLap({
  track: track3,
  car,
  collider,
  ledger,
  onRollover({ delta }) {
    // The car is already back on the grid: collapse the interpolation window
    // and put the camera behind it, or the "1" beat is spent watching the whole
    // track swing past.
    syncPrevious();
    scene.camera.snap(chasePose());
    // The comparison the prototype exists to make: this lap's `$/sec` against
    // the lap it was measured against. Silent on lap 1, which has none.
    if (delta !== null) hud.flashRate(delta);
  },
});

/**
 * Session restart, `endless_dev.lua`'s `R`: the run goes back to zero, the
 * *tuning* does not. That asymmetry is the whole point of the TUNE/DEFAULTS
 * split — restoring the authored knobs is a separate, deliberate act (`0`).
 *
 * The run's own state — cash, lap counter, best rate, the car on the grid —
 * belongs to `sim/lap.ts`; what is left here is the render side of a teleport.
 */
function restartSession(): void {
  lap.restart();
  syncPrevious();
  scene.camera.snap(chasePose());
}

const hud = createHud({
  ledger,
  car,
  camera: scene.camera.knobs,
  onRestart: restartSession,
  onTuneChange(key) {
    // The sim reads `TUNE` directly; only the knobs that have to be *pushed*
    // somewhere are handled here. `lineAlpha` is the map's first legibility
    // fallback, and it is a render-side property, not a per-step read.
    if (key === "lineAlpha") scene.track.setLineAlpha(TUNE.lineAlpha);
  },
});
scene.track.setLineAlpha(TUNE.lineAlpha);

/** Which checkpoint the pads are currently lit for. `-1` forces the first push. */
let shownCp = -1;

// The panel is the supported way to tune now, but the console still reaches the
// same objects — a field the panel does not expose is one assignment away, and
// mutating them from either side is equivalent.
(window as unknown as { car: Car }).car = car;
(window as unknown as { track: typeof scene.track }).track = scene.track;
(window as unknown as { cam: typeof scene.camera.knobs }).cam = scene.camera.knobs;

startLoop({
  step(dt) {
    syncPrevious();
    // The grid-start beat freezes the world, and freezing means *everything*:
    // the clocks hold with the car, so the held frames cost nothing in `$/sec`.
    // Input is still drained so a key held across the line does not fire twice
    // on the green.
    if (!lap.beginStep(dt)) {
      keyboard.takeStep();
      return;
    }
    stepCar(car, keyboard.takeStep(), dt, collider.resolveMove);
    // The session and lap clocks advance on the fixed step, never on wall time:
    // every `$/sec` this prototype reports is a ratio against this number, so it
    // has to be the same on any display. (The HUD's flash fade is the one thing
    // that runs on wall time — it is cosmetic.)
    ledger.step(dt);
    // After the car has moved: checkpoint crossings, and the rollover they
    // eventually trigger. The camera follows *after* that, so on the rollover
    // step it reads the pose the grid start just wrote.
    lap.endStep(dt);
    // Camera spring on the same fixed cadence as the sim: a spring integrated
    // against frame deltas is a different camera at 60Hz and at 144Hz.
    scene.camera.follow(chasePose(), dt);
  },
  render(alpha, stats) {
    scene.draw({
      x: previous.x + (car.x - previous.x) * alpha,
      z: previous.z + (car.z - previous.z) * alpha,
      facingAngle: angle.lerp(previous.facingAngle, car.facingAngle, alpha),
      velAngle: angle.lerp(previous.velAngle, car.velAngle, alpha),
      drifting: car.isDrifting,
    });

    hud.update(stats.wallSeconds);
    hud.setBeat(lap.beat);

    // Pushed on change rather than every frame: the pads only move between the
    // target and the faded state when a checkpoint is crossed.
    if (lap.nextCp !== shownCp) {
      shownCp = lap.nextCp;
      scene.track.setCheckpointsCrossed(lap.faded);
    }

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
        `wall       ${collider.touching ? "CONTACT" : "-"}   bounce ${Math.hypot(collider.bounceX, collider.bounceZ).toFixed(0)} px/s`,
        ``,
        // The lap line: what the race thinks is happening, next to the number it
        // is being judged on. `best` is the rate a promotion has to beat.
        `lap        ${ledger.lap}   cp ${lap.nextCp + 1}/${track3.checkpoints.length}   ${lap.held ? "HELD" : `${ledger.lapTime.toFixed(1)}s`}`,
        `rate       lap ${ledger.lapRate.toFixed(2)}   best ${lap.bestRate === null ? "-" : lap.bestRate.toFixed(2)}   (${lap.promoteMode})`,
        ``,
        // Echoed because they are edited live from the console: without this you
        // cannot tell a tuning you set from one you thought you set.
        `cam        blend ${scene.camera.knobs.velBlend.toFixed(2)}   k ${scene.camera.knobs.stiffness.toFixed(0)}   zeta ${scene.camera.knobs.damping.toFixed(2)}`,
        ``,
        `arrows/AD steer   Z brake   X drift   C boost   R restart`,
        `\` hud   0 defaults   P promote mode`,
      ].join("\n");
    }
  },
});

/**
 * The two session-level keys. T8's `J`/`K`/`L` ledger stubs are **gone**: laps
 * now pay their own checkpoints, and those three codes are the driving buttons
 * (`io/keyboard.ts` binds `J`/`K`/`L` alongside `Z`/`X`/`C`), so with real cash
 * flowing a drift tap would have been quietly paying itself $25 a press and
 * poisoning the one number this prototype reports. The wiring they exercised —
 * `award`, `rollover`, `flashRate` — stays, now driven by `sim/lap.ts`.
 *
 * - `R` — restart the session. Zeroes the run, keeps the tuning.
 * - `P` — flip the promotion rule (`endless_dev.lua:591`). `best` is the game;
 *   `always` replaces the line with whatever lap just finished, which is how you
 *   look at a *specific* lap's ghosts rather than your best one's.
 */
window.addEventListener("keydown", (e) => {
  if (e.code === "KeyR") restartSession();
  else if (e.code === "KeyP") {
    lap.promoteMode = lap.promoteMode === "always" ? "best" : "always";
  }
});
