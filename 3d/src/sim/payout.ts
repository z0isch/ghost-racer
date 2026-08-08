/**
 * Where a payout happened — the one thing `sim/cash.ts` deliberately refuses to
 * carry.
 *
 * The ledger is the tally: `award(kind, amount)` and nothing about position,
 * because the effects that decorate a payout belong to whoever awards it. But
 * all three of those awarding callers — `lap.ts` at a checkpoint, `coins.ts` at
 * a coin, `contact.ts` at a boosted ghost — want to say the same sentence to
 * whoever is decorating (`render/popups.ts` today, `sfx` when there is any), so
 * the sentence is declared once here rather than three times in three `Deps`.
 *
 * It is a sim-side type on purpose: a payout site is a fact about the run, and
 * a caller that wires it to nothing is the normal case (every `onPay` is
 * optional, and the sim is complete without one).
 */

import type { CashKind } from "./cash.js";

export interface Payout {
  /** Center of the thing that paid, in source pixels. */
  readonly x: number;
  readonly z: number;
  readonly amount: number;
  readonly kind: CashKind;
  /** A ghost hit, so the decoration can be quieter than a coin's. */
  readonly ghost?: boolean;
}

/** Told about a payout the instant it lands, on the fixed step. */
export type OnPay = (payout: Payout) => void;
