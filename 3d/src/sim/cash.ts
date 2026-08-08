/**
 * The cash ledger and the `$/sec` arithmetic (T8, issue #9).
 *
 * `$/sec` is the prototype's entire output — the number laps are compared on —
 * so it is sim state, not a HUD detail, and it lives here rather than inside
 * `hud/hud.ts`. Two callers depend on that:
 *
 * - The HUD **reads** it: rolling rate, session rate, last lap, lap history.
 * - T9's `lap.ts` **decides** on it: a lap is promoted when its `lapRate` beats
 *   the stored best, so promotion cannot depend on a number computed in a panel.
 *
 * Ported from the `State.cash*` / `State.last_laps` machinery in
 * `endless_dev.lua` (`add_cash` ~155, `trim_cash_events` 168, `rollover` 449,
 * `rolling_rate` 723). No popups and no `sfx` — this is the tally, and the
 * effects that decorate a payout belong to whoever awards it.
 *
 * Kinds: cash is split `cp` / `coin` only because the always-on HUD line breaks
 * it down that way. A boosted ghost hit pays as `coin` deliberately — it folds
 * into the coin tally rather than inventing a third bucket, exactly as
 * `endless_dev.lua` does it.
 */

export type CashKind = "cp" | "coin";

/** One finished lap, as the HUD's history list shows it. */
export interface LapRecord {
  /** 1-based lap number within the session. */
  lap: number;
  /** Seconds the lap took. */
  t: number;
  cash: number;
  hits: number;
  /** `cash / t` — the number the whole prototype is about. */
  rate: number;
}

/** Laps kept in the history list, `endless_dev.lua:57`. */
export const LAST_LAPS_KEPT = 5;

/** A timestamped payout, kept only while it is inside the rolling window. */
interface CashEvent {
  t: number;
  amount: number;
}

export interface CashLedger {
  /** Session totals. */
  readonly cash: number;
  readonly time: number;
  readonly cpCash: number;
  readonly coinCash: number;
  readonly hits: number;

  /** Current lap, reset by `rollover`. */
  readonly lap: number;
  readonly lapTime: number;
  readonly lapCash: number;
  readonly lapHits: number;

  /** `cash / time`, 0 before the clock starts. */
  readonly sessionRate: number;
  /** `lapCash / lapTime` for the lap in progress. */
  readonly lapRate: number;
  /** Finished laps, oldest first, at most `LAST_LAPS_KEPT`. */
  readonly laps: readonly LapRecord[];

  /**
   * `$/sec` over the last `window` seconds. Trims events that have fallen out
   * of the window as it goes, so the event list stays O(window) rather than
   * O(session) — the window is a live knob, so the trim has to happen against
   * the value being asked about, not against a value stored at award time.
   *
   * Early in a session the divisor is the elapsed time, not the full window:
   * otherwise the first lap reads low purely because the session is young.
   */
  rollingRate(window: number): number;

  /** Advance the session and lap clocks by one fixed step. */
  step(dt: number): void;
  /** Pay in. `x`/`z` are not taken: popups are the awarding caller's business. */
  award(kind: CashKind, amount: number): void;
  /** Count a ghost hit. Hits are tallied, never paid — a boosted hit `award`s too. */
  countHit(): void;
  /** Close the lap: file its record, zero the lap tallies, return the record. */
  rollover(): LapRecord;
  /** Session restart: everything back to zero. Does not touch `TUNE`. */
  reset(): void;
}

export function createLedger(): CashLedger {
  let cash = 0;
  let time = 0;
  let cpCash = 0;
  let coinCash = 0;
  let hits = 0;

  let lap = 1;
  let lapTime = 0;
  let lapCash = 0;
  let lapHits = 0;

  let events: CashEvent[] = [];
  let laps: LapRecord[] = [];

  return {
    get cash() {
      return cash;
    },
    get time() {
      return time;
    },
    get cpCash() {
      return cpCash;
    },
    get coinCash() {
      return coinCash;
    },
    get hits() {
      return hits;
    },
    get lap() {
      return lap;
    },
    get lapTime() {
      return lapTime;
    },
    get lapCash() {
      return lapCash;
    },
    get lapHits() {
      return lapHits;
    },
    get sessionRate() {
      return time > 0 ? cash / time : 0;
    },
    get lapRate() {
      return lapTime > 0 ? lapCash / lapTime : 0;
    },
    get laps() {
      return laps;
    },

    rollingRate(window) {
      const cutoff = time - window;
      events = events.filter((e) => e.t > cutoff);
      let sum = 0;
      for (const e of events) sum += e.amount;
      return sum / Math.max(0.001, Math.min(window, time));
    },

    step(dt) {
      time += dt;
      lapTime += dt;
    },

    award(kind, amount) {
      cash += amount;
      lapCash += amount;
      if (kind === "cp") cpCash += amount;
      else coinCash += amount;
      events.push({ t: time, amount });
    },

    countHit() {
      hits++;
      lapHits++;
    },

    rollover() {
      const record: LapRecord = {
        lap,
        t: lapTime,
        cash: lapCash,
        hits: lapHits,
        rate: lapTime > 0 ? lapCash / lapTime : 0,
      };
      laps.push(record);
      if (laps.length > LAST_LAPS_KEPT) laps.shift();

      lap++;
      lapTime = 0;
      lapCash = 0;
      lapHits = 0;
      return record;
    },

    reset() {
      cash = 0;
      time = 0;
      cpCash = 0;
      coinCash = 0;
      hits = 0;
      lap = 1;
      lapTime = 0;
      lapCash = 0;
      lapHits = 0;
      events = [];
      laps = [];
    },
  };
}
