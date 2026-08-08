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

import { createDemoState, stepDemo, type DemoState } from "./src/sim/demo.js";
import { createScene } from "./src/render/scene.js";

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
const state: DemoState = createDemoState();
let previousAngle = state.angle;

const probe = document.getElementById("probe");
let probeAt = 0;

startLoop({
  step(dt) {
    previousAngle = state.angle;
    stepDemo(state, dt);
  },
  render(alpha, stats) {
    scene.draw(previousAngle + (state.angle - previousAngle) * alpha);

    // Timestep proof: sim seconds should track wall seconds minus dropped time,
    // whatever the display refresh rate is.
    if (probe && stats.wallSeconds - probeAt > 0.25) {
      probeAt = stats.wallSeconds;
      const drift = stats.wallSeconds - stats.droppedSeconds - stats.simSeconds;
      probe.textContent = [
        `fixed      ${FIXED_HZ}Hz  (dt ${(FIXED_DT * 1000).toFixed(3)}ms)`,
        `render     ${stats.fps.toFixed(1)} fps`,
        `steps      ${stats.steps}  (this frame ${stats.stepsThisFrame}, max ${stats.maxStepsInFrame})`,
        `sim        ${stats.simSeconds.toFixed(2)}s`,
        `wall       ${stats.wallSeconds.toFixed(2)}s  (dropped ${stats.droppedSeconds.toFixed(2)}s)`,
        `drift      ${(drift * 1000).toFixed(1)}ms  (< 1 step = ${(FIXED_DT * 1000).toFixed(1)}ms)`,
        `alpha      ${alpha.toFixed(3)}`,
      ].join("\n");
    }
  },
});
