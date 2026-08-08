/**
 * The coin field: the second cash source, and the one that competes with the
 * ghost chain (T12, issue #13).
 *
 * Ported from `endless_dev.lua` — `coin_taken` (:181), `top_up_coins` (:195),
 * `coins_update` (:209) — plus the `State.coin_slots` seeding in
 * `restart_session` (:550-555) and the `top_up_coins()` call inside `rollover`
 * (:499).
 *
 * ## Authored slots, not random tiles
 *
 * The field is the track's own `coins` list — the real race's lap-1 gold set,
 * exported by T3 and validated by `io/trackData.ts`. So a collected coin always
 * refreshes back at one of the same authored spots, and the routing problem is
 * stable lap over lap. The slot list's fixed size caps the field at that track's
 * authored count even when `TUNE.maxCoins` is nudged past it.
 *
 * That is also why T5's exported `onRoad` is not used here: it was offered for
 * a field that had to find its own drivable tiles, and this one doesn't.
 *
 * ## Top up to N, and only at the line
 *
 * The refill is `maxCoins - present`, never a flat `+N`, so **uncollected coins
 * persist across laps by design** — a lap that skips the far coin finds it still
 * sitting there next time round. And the refill happens at a rollover or a
 * restart, nowhere else: topping up continuously would respawn a coin under the
 * car the instant it was taken, which is a money printer rather than a route.
 *
 * The consequence for tuning is deliberate and worth knowing at the slider:
 * **`maxCoins` takes effect at the next rollover**, not on the drag. Contrast
 * `sim/ghosts.ts`, which re-lays its field the moment `TUNE.ghosts` moves — the
 * ghost count is a property of a line, while a coin is a thing standing on the
 * track that was either collected or wasn't.
 */

import { CAR_SIZE, type Car } from "./car.js";
import type { CashLedger } from "./cash.js";
import { TUNE } from "./tune.js";
import { coinRect, type Rect } from "../io/trackData.js";
import type { TrackExport } from "../io/types.js";

export interface CoinDeps {
  readonly track: TrackExport;
  /** Tested against the pickup radius every step. Never written. */
  readonly car: Car;
  /** Collected coins pay into it as `"coin"` kind. */
  readonly ledger: CashLedger;
}

export interface CoinField {
  /** Coins currently on the track. `endless_dev.lua`'s `#State.coins`. */
  readonly count: number;
  /** Authored slots in export order, so a renderer can build one pool up front. */
  readonly slots: readonly Rect[];
  /** Whether slot `i` currently holds a coin. Parallel to `slots`. */
  present(i: number): boolean;

  /**
   * One fixed step: collect every coin the car is touching, paying for each.
   *
   * Called *after* the car has moved and after `lap.endStep`, mirroring
   * `endless_dev.lua:659`. There is no `dt` — a coin is a position test, and
   * nothing about it integrates.
   */
  step(): void;

  /** At the line: refill the shortfall. Called from the rollover. */
  topUp(): void;
  /** Session restart: every authored slot filled again, up to `maxCoins`. */
  restart(): void;
}

export function createCoins(deps: CoinDeps): CoinField {
  const { track, car, ledger } = deps;

  /** Fixed for the session: the export is not reloaded mid-run. */
  const slots: readonly Rect[] = track.coins.map((c) => coinRect(c, track.tileSize));

  /** One flag per slot — `State.coins` as a dense array rather than a list. */
  let present: boolean[] = [];

  function topUp(): void {
    let need = TUNE.maxCoins - countPresent();
    for (let i = 0; i < slots.length && need > 0; i++) {
      if (present[i] !== true) {
        present[i] = true;
        need--;
      }
    }
  }

  function countPresent(): number {
    let n = 0;
    for (const p of present) if (p) n++;
    return n;
  }

  const field: CoinField = {
    get count() {
      return countPresent();
    },
    slots,

    present(i) {
      return present[i] === true;
    },

    step() {
      // The pickup circle sits on the car's *center*; positions everywhere in
      // this codebase are top-left corners.
      const cx = car.x + CAR_SIZE / 2;
      const cz = car.z + CAR_SIZE / 2;
      for (let i = 0; i < slots.length; i++) {
        if (present[i] !== true) continue;
        if (!circleOverlapsRect(cx, cz, TUNE.coinRadius, slots[i]!)) continue;
        present[i] = false;
        ledger.award("coin", TUNE.coinPay);
      }
    },

    topUp,

    restart() {
      present = [];
      topUp();
    },
  };

  field.restart();
  return field;
}

/**
 * `util.circ_rect_overlap` — closest-point: clamp the circle's center into the
 * rect, then test the distance to it. Strictly less than, so a circle exactly
 * grazing the tile's edge does not collect (`util.circ_overlap`'s rule for
 * tangency, applied here for consistency).
 */
function circleOverlapsRect(cx: number, cz: number, r: number, rect: Rect): boolean {
  const nx = Math.max(rect.x, Math.min(cx, rect.x + rect.w));
  const nz = Math.max(rect.y, Math.min(cz, rect.y + rect.h));
  const dx = cx - nx;
  const dz = cz - nz;
  return dx * dx + dz * dz < r * r;
}
