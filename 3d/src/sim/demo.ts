/**
 * Placeholder sim so the harness has something to tick. Exists only to prove the
 * fixed timestep runs and that `render/` can draw `sim/` state across the seam.
 *
 * Delete this when the real car model lands (T4).
 */

export const DEMO_SPIN_RATE = Math.PI / 2; // rad/s

export interface DemoState {
  /** Radians about the vertical axis. */
  angle: number;
}

export function createDemoState(): DemoState {
  return { angle: 0 };
}

export function stepDemo(state: DemoState, dt: number): void {
  state.angle += DEMO_SPIN_RATE * dt;
}
