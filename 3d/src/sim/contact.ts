/**
 * Ghost contact: the third cash source, and the one the whole prototype is
 * about (T12, issue #13).
 *
 * A near-verbatim port of `contact` (`endless_dev.lua:398-446`), minus the
 * hazard branch — see below.
 *
 * ## Contact is not collision
 *
 * The car passes straight through a ghost. Nothing here touches the collider,
 * the car's position, or its heading: a hit pays cash and shoves the car
 * *forward* along its own travel direction (`car.applyBoost`), which is the
 * inversion this prototype is built on — ghosts are a pickup laid on your own
 * best line, not a body to dodge.
 *
 * Each ghost is worth exactly one hit per lap: a hit marks it `take(i)`, which
 * drops it out of posing, and therefore out of both this test and the draw
 * (`render/ghosts.ts`), until the rollover restores the field. Without that the
 * car could park inside one and farm boosts at 120Hz.
 *
 * `touched(i)` is the *rising*-edge latch, and it exists for the case where a
 * ghost is overlapped but not hit — `headOnOnly` on, with the car not closing.
 * Turning into a ghost the car is already sitting inside must not fire late.
 * That state lives on the field rather than here because it is per-ghost lap
 * state, cleared by the same rollover that restores `taken`.
 *
 * ## The hazard branch is deliberately not ported
 *
 * With `boostOnHit` **off**, `endless_dev.lua` ends the run outright
 * (`State.ended`). There is no ended state in `3d/` — no fail screen, no
 * stopped world — and inventing one is not this ticket's business and not the
 * prototype's premise. So the knob's off position means something narrower and
 * still useful: a hit is **tallied and pays nothing**. That is the control
 * condition for the map's open payout-ratio question — drive the same line with
 * the ghost chain worth zero, and read what `$/sec` does. `render/ghosts.ts`
 * still tints the field pink there, which reads correctly as "these are not
 * paying you".
 *
 * ## What it does not do
 *
 * No `sfx`, no `effect.hitstop` — T8 dropped the `hitstop` knob for want of an
 * effect bus, and this is the beat it would have decorated. If one ever lands,
 * this is the call site.
 *
 * The one piece of feedback a hit does produce is the boost flame, and it is
 * produced *indirectly*: `applyBoost` sets `car.boostFlameT`, and
 * `render/kart.ts` draws it. Nothing here reaches at the renderer, and the flame
 * is the same one the manual boost and the drift cash-out raise.
 */

import { applyBoost, CAR_SIZE, type Car } from "./car.js";
import type { CashLedger } from "./cash.js";
import type { GhostField } from "./ghosts.js";
import { TUNE } from "./tune.js";

export interface ContactDeps {
  /** Boosted by a hit, and the source of the closing test's travel vector. */
  readonly car: Car;
  /** Posed, taken and edge-latched. Never re-laid from here. */
  readonly ghosts: GhostField;
  /** Hits are counted here, and a boosted hit pays into it as `"coin"`. */
  readonly ledger: CashLedger;
}

export interface ContactTest {
  /**
   * One fixed step, run last — after the car has moved, after `lap.endStep`,
   * after the lap's recording sample.
   *
   * `graceT` is `lap.graceT`: the post-promotion immunity window. A fresh field
   * appears at the rollover with some of it standing on the grid, and the grace
   * is what stops the first ghost being free money before the car has moved off
   * the line. Passed in rather than read off the lap, so this file has no
   * dependency on lap machinery — laps already decrement it in `endStep`.
   */
  step(graceT: number): void;
}

export function createContact(deps: ContactDeps): ContactTest {
  const { car, ghosts, ledger } = deps;

  return {
    step(graceT) {
      if (graceT > 0) return;

      // Circles on centers, both at `hitRadius / 2` — the knob is read as a
      // *diameter*, which is what makes `render/ghosts.ts` draw a ghost at
      // `hitRadius` and still have what you see be what you hit.
      const cx = car.x + CAR_SIZE / 2;
      const cz = car.z + CAR_SIZE / 2;
      const r = TUNE.hitRadius / 2;
      // Actual travel, not facing: a spun car reads correctly, which is exactly
      // the case `headOnOnly` is trying to judge.
      const travX = Math.cos(car.velAngle) * car.vel;
      const travZ = Math.sin(car.velAngle) * car.vel;

      const count = ghosts.count;
      for (let i = 0; i < count; i++) {
        // Already null for a ghost taken this lap.
        const g = ghosts.pose(i);
        let overlapping = false;

        if (g !== null) {
          const gx = g.x + CAR_SIZE / 2;
          const gz = g.z + CAR_SIZE / 2;
          const dx = cx - gx;
          const dz = cz - gz;
          const reach = r + r;
          // `util.circ_overlap`: tangent circles do not overlap.
          overlapping = dx * dx + dz * dz < reach * reach;

          if (overlapping && !ghosts.touched(i)) {
            const closing = travX * Math.cos(g.head) + travZ * Math.sin(g.head) < 0;
            if (closing || !TUNE.headOnOnly) {
              ledger.countHit();
              if (TUNE.boostOnHit) {
                applyBoost(car, TUNE.boostAmount);
                if (TUNE.boostPay > 0) ledger.award("coin", TUNE.boostPay);
                // Consumed for the lap, and no longer overlapping anything: it
                // stops being posed or drawn at all until the rollover.
                ghosts.take(i);
                overlapping = false;
              }
            }
          }
        }

        ghosts.setTouched(i, overlapping);
      }
    },
  };
}
