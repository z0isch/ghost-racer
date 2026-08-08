/**
 * `angle.lua`, transcribed. Two functions, both load-bearing for the car model.
 *
 * Angles are radians in the source's top-down space: 0 = +x (east), increasing
 * toward +y (south). `render/` maps y -> z and flips the sign for three.js;
 * nothing in `sim/` knows about that.
 */

/** Wraps into `[0, 2pi)`. Matches Lua's floor-based modulo for negatives. */
export function normalize(a: number): number {
  return a - 2 * Math.PI * Math.floor(a / (2 * Math.PI));
}

/**
 * Lerps `a` toward `b` along the *short* way round, so a heading never takes
 * the long route through 2pi. `t` is clamped to 1 at the top but deliberately
 * not at the bottom: callers pass `rate * dt`.
 */
export function lerp(a: number, b: number, t: number): number {
  let diff = b - a;
  diff = diff - 2 * Math.PI * Math.floor((diff + Math.PI) / (2 * Math.PI));
  return a + diff * Math.min(t, 1);
}
