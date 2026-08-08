/**
 * The live-tuning table, ported from `endless_dev.lua:96-138` (T8, issue #9).
 *
 * Three pieces, exactly as the Lua has them, and the split between them is the
 * whole point:
 *
 * - `DEFAULTS` — the **authored** start. Frozen. Never written.
 * - `TUNE` — what the game reads, every step. Mutable, and mutated live.
 * - `KNOBS` — the metadata that says how each field may be moved.
 *
 * A session restart (T9's `R`) resets the *run*, not the tuning: it must not
 * touch `TUNE`, or every restart would silently throw away the tuning pass you
 * were in the middle of. `restoreDefaults()` is the only thing that puts `TUNE`
 * back, and it is a deliberate act — the `0` key in the Lua, a button in the
 * lil-gui panel here.
 *
 * This file is in `sim/` because `TUNE` is read by the sim (`ghosts.ts`,
 * `lap.ts`, T12's payouts) and only *edited* by the HUD. It knows nothing about
 * lil-gui; `hud/hud.ts` walks `KNOBS` and builds controllers from it, so adding
 * a knob is one entry here and nothing in the HUD.
 *
 * ## Ported deliberately incompletely
 *
 * - **`hitstop`** is dropped. It is a `effect.hitstop` punch on the 2D engine's
 *   own effect bus; nothing in `3d/` has one, so a knob for it would read as a
 *   dead control. It comes back with the beat it decorates, if ever.
 * - **`max`** is supplied for every numeric knob, where the Lua leaves several
 *   open-ended. A slider needs two ends. The ceilings are authored headroom, not
 *   claims about the model — nudge one if a tuning pass hits it.
 */

/**
 * Payout and field tuning. Field names are `endless_dev.lua`'s `DEFAULTS` keys
 * in camelCase; the Lua name is the obvious de-camel of each.
 *
 * Consumers are mostly still ahead of us: T10 reads the ghost fields, T12 the
 * coin and payout ones. `rateWindow` and `lineAlpha` are live today.
 */
export interface Tune {
  /** Cash per checkpoint crossed. */
  cpPay: number;
  /** Cash per coin collected. */
  coinPay: number;
  /** Ghost contact radius, source pixels. */
  hitRadius: number;
  /** Seconds after a promotion during which ghost contact is ignored. */
  spawnGrace: number;
  /** Only count ghost contact when closing on the ghost head-on. */
  headOnOnly: boolean;
  /** Coin pickup radius, source pixels. */
  coinRadius: number;
  /** Coins the field is topped back up to. Capped by the track's authored slots. */
  maxCoins: number;
  /** Ghosts laid along the promoted line. */
  ghosts: number;
  /** Seconds the rolling `$/sec` readout averages over. */
  rateWindow: number;
  /**
   * Opacity of the promoted line's ground ribbon. **0 is the decision**, not a
   * placeholder: the map's first legibility fallback is turning this up, and it
   * only gets turned up if the `$/sec` curve plateaus. See `render/track.ts`.
   */
  lineAlpha: number;
  /** Opacity of the parked ghost karts (T11). */
  ghostAlpha: number;
  /** Ghosts face along the promoted line's own direction of travel. */
  sameDir: boolean;
  /** Ghost drift speed along the line. 0 parks them. */
  ghostSpeed: number;
  /** Ghost contact is a boost pickup rather than a run-ending hazard. */
  boostOnHit: boolean;
  /**
   * Impulse a boosted ghost hit pays, px/s — added on top of `topVel` and bled
   * back down by `OVERSPEED_DECAY` (100 px/s^2 in `sim/car.ts`), which is what
   * makes this number a *duration* as much as a speed.
   *
   * Authored at 50 from the Lua, and that was measured to be nothing here: at a
   * mid-spec `topVel` of 110 the excess was gone in 0.5s and bought 12px of
   * track, under one car length. A collected ghost has to be worth feeling, so
   * it is 150 — 1.5s of overspeed and ~110px gained, about a second of driving.
   */
  boostAmount: number;
  /**
   * Cash a boosted ghost hit pays. Authored at 5 against `coinPay` 25 — the
   * map's open payout-ratio risk, and the number this whole HUD exists to judge.
   */
  boostPay: number;
  /** One ghost paces the line at the recorded speed instead of parking. */
  paceGhost: boolean;
}

export const DEFAULTS: Readonly<Tune> = Object.freeze({
  cpPay: 45,
  coinPay: 25,
  hitRadius: 50,
  spawnGrace: 0,
  headOnOnly: false,
  coinRadius: 10,
  maxCoins: 10,
  ghosts: 3,
  rateWindow: 10,
  lineAlpha: 0.1,
  ghostAlpha: 0.1,
  sameDir: true,
  ghostSpeed: 0,
  boostOnHit: true,
  boostAmount: 150,
  boostPay: 5,
  paceGhost: true,
});

/** Ceiling on the ghost count, `endless_dev.lua:52`. */
export const MAX_GHOSTS = 50;

/** What the game reads. Mutated live; never replaced, so imports stay valid. */
export const TUNE: Tune = { ...DEFAULTS };

type NumericKey = {
  [K in keyof Tune]: Tune[K] extends number ? K : never;
}[keyof Tune];
type BooleanKey = {
  [K in keyof Tune]: Tune[K] extends boolean ? K : never;
}[keyof Tune];

export type KnobSpec =
  | { key: NumericKey; min: number; max: number; step: number; bool?: never }
  | { key: BooleanKey; bool: true };

/** Knob order is the Lua's, which is the order they are usually reached for. */
export const KNOBS: readonly KnobSpec[] = [
  { key: "cpPay", min: 0, max: 200, step: 1 },
  { key: "coinPay", min: 0, max: 200, step: 1 },
  { key: "hitRadius", min: 1, max: 100, step: 1 },
  { key: "spawnGrace", min: 0, max: 10, step: 0.25 },
  { key: "headOnOnly", bool: true },
  { key: "coinRadius", min: 1, max: 60, step: 1 },
  { key: "maxCoins", min: 0, max: 20, step: 1 },
  { key: "ghosts", min: 0, max: MAX_GHOSTS, step: 1 },
  { key: "rateWindow", min: 1, max: 60, step: 1 },
  { key: "lineAlpha", min: 0, max: 1, step: 0.05 },
  { key: "ghostAlpha", min: 0, max: 1, step: 0.05 },
  { key: "sameDir", bool: true },
  { key: "ghostSpeed", min: 0, max: 3, step: 0.05 },
  { key: "boostOnHit", bool: true },
  { key: "boostAmount", min: 0, max: 300, step: 10 },
  { key: "boostPay", min: 0, max: 200, step: 5 },
  { key: "paceGhost", bool: true },
];

/**
 * Put `TUNE` back to the authored start, in place. In place because `TUNE` is
 * imported by value all over the sim: replacing the object would leave every
 * consumer holding the old one.
 */
export function restoreDefaults(): void {
  Object.assign(TUNE, DEFAULTS);
}
