/**
 * Lap machinery: checkpoints, `rollover()`, promotion, and the grid-start beat
 * (T9, issue #10). Ported from `endless_dev.lua`'s `laps` (:504), `rollover`
 * (:451) and the countdown gate at the top of `_update` (:634).
 *
 * **Laps own the beat; ghosts own the line.** A lap is cross cp1 -> cp2 -> cp3
 * -> rollover, in authored order like a real race, and `rollover()` is the only
 * thing in the prototype that decides *which* lap becomes the ghost line — the
 * promotion rule is `$/sec`, so the decision has to sit next to the lap clock,
 * not inside the ghost field. What it does *not* do is know what a line is: it
 * calls `GhostLine.promote()` and lets `sim/ghosts.ts` (T10) record, downsample
 * and lay out.
 *
 * ## The grid start is deliberate
 *
 * Every lap ends with the car teleported back to the spawn tile, stopped,
 * boosts refilled, and the world frozen for a beat showing "1". This is the
 * map's open risk 3 — a hard rupture at the line reads more violently from a
 * chase camera than it did top-down — and it is kept, not softened: a lap's
 * time is only comparable with the lap before it if every lap starts from the
 * same pose, and `$/sec` compared between laps is the entire output of this
 * prototype. Judge it from the driver's seat; do not quietly smooth it.
 *
 * ## The freeze is a gate, not a pause flag
 *
 * `beginStep` returns false while the world is held, and the caller must then
 * step *nothing* — not the car, not the camera, and above all not the clocks.
 * Held frames have to cost nothing in `$/sec`, or the beat itself would tax the
 * number every lap is judged on.
 */

import { CAR_SIZE, resetCar, type Car } from "./car.js";
import type { Collider } from "./collision.js";
import type { CashLedger, LapRecord } from "./cash.js";
import { TUNE } from "./tune.js";
import type { OnPay } from "./payout.js";
import { checkpointRect, type Rect } from "../io/trackData.js";
import type { TrackExport } from "../io/types.js";

/**
 * The post-rollover countdown, `endless_dev.lua:82-83`. The world holds still
 * for `COUNT_HOLD` showing "1", then unfreezes and "GO" lingers for `COUNT_GO`.
 * One digit only — this is a beat to mark the lap boundary, not a real grid
 * start.
 */
export const COUNT_HOLD = 0.7;
export const COUNT_GO = 0.5;

/**
 * The ghost field, as laps need it — implemented by `sim/ghosts.ts` (T10) and
 * absent until then.
 *
 * This is the whole of the lap/ghost seam. Laps say *when* a line is worth
 * promoting; the field decides what a line is, records it, downsamples it and
 * lays ghosts along it. Nothing about polylines, arc length or `taken` leaks
 * through here.
 */
export interface GhostLine {
  /**
   * Install the lap just finished as the promoted line. Called only when the
   * lap won on `$/sec`. An implementation is free to ignore a recording too
   * short to be a line (`endless_dev.lua`'s `#rec > 1` guard) — laps do not
   * inspect it.
   */
  promote(): void;
  /**
   * Per-lap ghost reset at the line: restore every `taken` ghost, drop the
   * touch edges, and start recording afresh. Runs on every rollover, promoted
   * or not.
   */
  rollover(): void;
  /** Session restart: back to the seeded reference line. */
  restart(): void;
}

/**
 * How a single checkpoint pad should render, consumed by `render/track.ts`'s
 * `setCheckpointStates`.
 *
 * The 2D game had only the first two — `road.draw_checkpoint` is called with
 * `faded = i ~= State.next_cp` (`endless_dev.lua:832`), so exactly one pad is
 * ever lit and everything else, ahead or behind, is dimmed the same way. From a
 * top-down view that is enough: a faded pad behind you is visibly behind you.
 * From a chase cam it is not, so the pads already taken are dropped from the
 * world entirely and what stays on the ground is the lap you still have to
 * drive. They all come back at the next rollover.
 */
export type CheckpointState =
  /** The one to drive through: full fill, dark outline. */
  | "target"
  /** Still to come this lap: fill dropped, outline in the fill colour. */
  | "pending"
  /** Taken this lap. Not drawn at all. */
  | "crossed";

/**
 * How `rollover()` decides. `"best"` promotes only a lap that beats the stored
 * rate; `"always"` replaces the line wholesale with whatever just finished,
 * even a bad lap (`endless_dev.lua:449`, the `P` key). A debug affordance —
 * `"best"` is the game.
 */
export type PromoteMode = "best" | "always";

/** What the composition root is told when a lap closes. */
export interface RolloverEvent {
  /** The lap just filed, straight from the ledger. */
  readonly record: LapRecord;
  /** Whether this lap's line was installed as the new ghost line. */
  readonly promoted: boolean;
  /**
   * `lapRate` minus the rate it was measured against — the previously promoted
   * lap's. `null` on the first lap of a session, when there is nothing to
   * compare against and the HUD should stay quiet.
   */
  readonly delta: number | null;
}

/** What the countdown is showing, for whoever draws it. */
export interface Beat {
  readonly text: "1" | "GO";
  /** 1 while held; fades over the "GO" tail. */
  readonly alpha: number;
}

export interface LapDeps {
  readonly track: TrackExport;
  /** Reset to the spawn pose at every line. */
  readonly car: Car;
  /**
   * T5's collider carries the bounce accumulator *per car*, so a grid start has
   * to clear it alongside the car — otherwise a lap can open still carrying the
   * wall shove that ended the last one.
   */
  readonly collider: Collider;
  /** Checkpoints pay into it; `rollover()` files the lap through it. */
  readonly ledger: CashLedger;
  /** T10's field. Absent until then: laps run fine with no line to promote. */
  readonly ghosts?: GhostLine;
  /** Called after the lap has been filed and the car put back on the grid. */
  readonly onRollover?: (event: RolloverEvent) => void;
  /**
   * Told when a checkpoint pays, at the *car* — `endless_dev.lua:510` spawns
   * the pop there rather than at the pad, because what paid you is having
   * driven through it.
   */
  readonly onPay?: OnPay;
}

export interface LapRun {
  /** 0-based index of the checkpoint that must be crossed next. */
  readonly nextCp: number;
  /**
   * What `render/track.ts`'s `setCheckpointStates` wants: one state per
   * checkpoint, in authored order.
   *
   * Laps are strictly in order, so `nextCp` is the whole story — everything
   * before it has been taken this lap and is `"crossed"`, everything after is
   * `"pending"`. The 2D game drew both cases the same faded way
   * (`endless_dev.lua:832`); the split is a chase-cam concession, and it lives
   * here rather than in the view because "taken" is lap state.
   */
  readonly checkpointStates: readonly CheckpointState[];
  /** Best `$/sec` promoted so far this session. `null` before the first lap closes. */
  readonly bestRate: number | null;
  /** Seconds left on the countdown, `endless_dev.lua`'s `State.count_t`. */
  readonly countT: number;
  /** True while the world is held for the "1". */
  readonly held: boolean;
  /** The countdown readout, or `null` when the beat is over. */
  readonly beat: Beat | null;
  /**
   * Seconds of post-promotion ghost immunity left (`TUNE.spawnGrace`). Set when
   * a fresh line is installed, so a ghost laid on top of the grid does not
   * register the instant the lights change. Nothing reads it until T12's
   * contact test does.
   */
  readonly graceT: number;
  /** Debug: swap the promotion rule mid-session. */
  promoteMode: PromoteMode;

  /**
   * The countdown gate, run first in the fixed step. Advances the beat and
   * returns whether the world runs at all this step. **False means step
   * nothing** — clocks included.
   */
  beginStep(dt: number): boolean;
  /**
   * The checkpoint test, run last in the fixed step, after the car has moved.
   * May pay, may close the lap. Only call it on a step `beginStep` allowed.
   */
  endStep(dt: number): void;
  /**
   * Session restart (`endless_dev.lua:522`, the `R` key): the run goes back to
   * zero — cash, laps, ghost line, the beat — and the *tuning* does not. `TUNE`
   * is never touched here; restoring the authored knobs is the separate,
   * deliberate act `0` performs.
   */
  restart(): void;
}

export function createLap(deps: LapDeps): LapRun {
  const { track, car, collider, ledger, ghosts } = deps;

  /** The authored spawn pose in source pixels — a top-left corner, as always. */
  const spawn = {
    x: track.spawn.col * track.tileSize,
    z: track.spawn.row * track.tileSize,
    facing: track.spawn.facing,
  };
  /** Fixed for the session: the export is not reloaded mid-run. */
  const rects: readonly Rect[] = track.checkpoints.map((cp) =>
    checkpointRect(cp, track.tileSize),
  );

  let nextCp = 0;
  let bestRate: number | null = null;
  let countT = COUNT_HOLD + COUNT_GO;
  let graceT = TUNE.spawnGrace;
  let promoteMode: PromoteMode = "best";

  /**
   * Back to the grid: the same `resetCar` the session start uses, plus the
   * bounce state that lives with the collider rather than on the car.
   */
  function gridStart(): void {
    resetCar(car, spawn.x, spawn.z, spawn.facing);
    collider.reset();
  }

  /**
   * `rollover()` — the only place a line is promoted.
   *
   * Order matters and is the Lua's: decide promotion against the *lap in
   * progress* first (the ledger still holds its cash and clock), then file it,
   * then reset. Filing first would zero `lapRate` out from under the decision.
   */
  function rollover(): void {
    const lapRate = ledger.lapRate;
    const previousRate = bestRate;

    const promoted = promoteMode === "always" || bestRate === null || lapRate > bestRate;
    if (promoted) {
      ghosts?.promote();
      bestRate = lapRate;
      // A fresh field of ghosts appears on this step, some of them on the grid.
      // The grace window is what stops the first one counting before the car
      // has moved off the line.
      graceT = TUNE.spawnGrace;
    }

    const record = ledger.rollover();
    ghosts?.rollover();
    countT = COUNT_HOLD + COUNT_GO;
    gridStart();

    deps.onRollover?.({
      record,
      promoted,
      delta: previousRate === null ? null : lapRate - previousRate,
    });
  }

  return {
    get nextCp() {
      return nextCp;
    },
    get checkpointStates() {
      return rects.map<CheckpointState>((_, i) =>
        i === nextCp ? "target" : i < nextCp ? "crossed" : "pending",
      );
    },
    get bestRate() {
      return bestRate;
    },
    get countT() {
      return countT;
    },
    get held() {
      return countT > COUNT_GO;
    },
    get beat() {
      if (countT <= 0) return null;
      if (countT > COUNT_GO) return { text: "1" as const, alpha: 1 };
      return { text: "GO" as const, alpha: Math.min(1, countT / COUNT_GO) };
    },
    get graceT() {
      return graceT;
    },
    get promoteMode() {
      return promoteMode;
    },
    set promoteMode(mode: PromoteMode) {
      promoteMode = mode;
    },

    beginStep(dt) {
      if (countT > 0) {
        // Held is read *before* the decrement, exactly as the Lua does it: the
        // step that takes the counter across the COUNT_GO boundary is still a
        // held step, and the world starts moving on the next one.
        const held = countT > COUNT_GO;
        countT = Math.max(0, countT - dt);
        if (held) return false;
      }
      return true;
    },

    endStep(dt) {
      if (graceT > 0) graceT = Math.max(0, graceT - dt);

      // A track with no checkpoints has no laps: nothing to cross, nothing to
      // roll over. It would take a hand-edited export, but the alternative is a
      // crash on the first step.
      const target = rects[nextCp];
      if (target === undefined) return;

      // One checkpoint per step at most: the car cannot be inside the next
      // target on the same step it entered this one — they do not touch.
      if (overlapsCar(car, target)) {
        ledger.award("cp", TUNE.cpPay);
        deps.onPay?.({
          x: car.x + CAR_SIZE / 2,
          z: car.z + CAR_SIZE / 2,
          amount: TUNE.cpPay,
          kind: "cp",
        });
        nextCp++;
        if (nextCp >= rects.length) {
          nextCp = 0;
          rollover();
        }
      }
    },

    restart() {
      ledger.reset();
      ghosts?.restart();
      nextCp = 0;
      bestRate = null;
      countT = COUNT_HOLD + COUNT_GO;
      graceT = TUNE.spawnGrace;
      gridStart();
    },
  };
}

/**
 * `util.rect_overlap(car.rect(car), rect)` — AABB overlap on shared *interior*
 * area, so edge-adjacent rectangles do not count. The car is a 16x16 box hung
 * off its top-left corner (`car.lua:193`).
 */
function overlapsCar(car: Car, rect: Rect): boolean {
  return (
    car.x < rect.x + rect.w &&
    car.x + CAR_SIZE > rect.x &&
    car.z < rect.y + rect.h &&
    car.z + CAR_SIZE > rect.y
  );
}
