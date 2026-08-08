/**
 * The debug HUD: live knobs and the `$/sec` readout (T8, issue #9).
 *
 * Ported early rather than last, because it is the only instrument this
 * prototype has. Everything the map is trying to observe — whether the groove
 * flywheel spins — is a number on this panel, compared against the same number
 * one lap ago.
 *
 * Two halves, mirroring `endless_dev.lua`:
 *
 * - **Knobs.** `sim/tune.ts`'s `KNOBS` walked into lil-gui, plus the car's own
 *   live tuning, its upgrade levels, and T7's `ChaseKnobs` wired in as-is. The
 *   panel edits `TUNE` in place; it never owns a value. A few knobs also have
 *   keys — `0` restores the authored defaults, `[` / `]` move the ghost count —
 *   and those go through the same controllers, so panel and keyboard agree.
 * - **Readout.** The always-on core (cash, rolling `$/sec`) and a toggleable
 *   debug block (session rate, last lap, per-lap history, tallies), plus the
 *   post-rollover `$/sec`-delta flash.
 *
 * ## Why the split is where it is
 *
 * This file holds no state that anything else could want. The tuning lives in
 * `sim/tune.ts`, the money in `sim/cash.ts`, the camera's feel in
 * `render/camera.ts` — the HUD binds widgets to them and formats numbers. That
 * is what lets T9/T10/T12 change what the numbers *mean* without touching a
 * panel, and it is why a knob is one entry in `KNOBS` and nothing here.
 *
 * ## What is stubbed
 *
 * Nothing now. T9 landed `sim/lap.ts`, so checkpoints pay and rollovers flash
 * for real, and the `J`/`K`/`L` ledger stubs `loop.ts` carried are deleted.
 * Coins and ghost hits (T12) pay through the same `CashLedger` when they land —
 * no panel change.
 *
 * Two things here are not part of the toggleable instrument, because neither is
 * the instrument speaking: `setBeat`'s grid-start countdown, and the cash /
 * `$/sec` readout — that is the score, so backtick leaves it up.
 */

import GUI from "lil-gui";
import type { Car, Upgrades } from "../sim/car.js";
import { applyUpgrades, MID_SPEC } from "../sim/car.js";
import type { CashLedger } from "../sim/cash.js";
import type { Beat } from "../sim/lap.js";
import type { ChaseKnobs } from "../render/camera.js";
import {
  KNOBS,
  MAX_GHOSTS,
  TUNE,
  restoreDefaults,
  type Tune,
} from "../sim/tune.js";

/** Seconds the rollover delta stays up, and the tail it fades over (`:76-77`). */
const FLASH_TIME = 1.5;
const FLASH_FADE = 0.4;

export interface HudDeps {
  /** Where the readout is mounted. Defaults to `document.body`. */
  container?: HTMLElement;
  /** The money. Read every frame, never written here. */
  ledger: CashLedger;
  /** The car whose tuning and upgrade levels the panel edits, in place. */
  car: Car;
  /** T7's chase-camera knobs, wired in as the object it already exposes. */
  camera: ChaseKnobs;
  /**
   * Called after any `TUNE` field moves, with the key that moved. The sim reads
   * `TUNE` itself; this is for the knobs that have to be *pushed* somewhere —
   * `lineAlpha` into `render/track.ts`, and whatever T10/T12 need re-laid.
   */
  onTuneChange?(key: keyof Tune): void;
  /** Wired to the panel's session-restart button. T9 owns what a restart means. */
  onRestart?(): void;
}

export interface Hud {
  /**
   * Refresh the readout. Called once per rendered frame with the loop's
   * wall-clock seconds — the flash fade is cosmetic, so it runs on wall time,
   * not on the fixed step.
   */
  update(wallSeconds: number): void;
  /**
   * Show the post-rollover comparison: this lap's `$/sec` against the lap it was
   * measured against. T9 calls this from `rollover()`.
   */
  flashRate(delta: number): void;
  /**
   * Draw the grid-start countdown, or clear it with `null` (T9, issue #10).
   * `sim/lap.ts` owns the beat and its timing; this only paints it, and it
   * paints on the render frame rather than the fixed step because the alpha is
   * a fade, not a rule.
   */
  setBeat(beat: Beat | null): void;
  /**
   * Show/hide the instrument: the tuning panel and the debug block. The cash and
   * `$/sec` readout stays up either way. Bound to backtick.
   */
  toggle(): void;
  dispose(): void;
}

/** The panel's own stylesheet, injected once. Keeps `index.html` free of it. */
const CSS = `
.hud {
  position: fixed;
  top: 4px;
  left: 0;
  right: 0;
  z-index: 10;
  pointer-events: none;
  text-align: center;
  font: 12px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace;
  text-shadow: 0 1px 0 #000;
}
.hud-cash { font-size: 30px; font-weight: 700; color: #7bf59a; letter-spacing: 1px; }
.hud-rate { font-size: 14px; color: #cfd3da; }
.hud-flash { font-size: 14px; font-weight: 700; min-height: 21px; }
.hud-flash.up { color: #7bf59a; }
.hud-flash.down { color: #ff6b6b; }
.hud-debug { margin-top: 4px; color: #9aa0aa; white-space: pre; }
.hud-laps { color: #6f757e; white-space: pre; }

/* The countdown lives outside .hud on purpose: backtick hides the debug
   instrument, and the grid-start beat is not one — it is the game telling you
   the lap has started. draw_countdown (endless_dev.lua:759) scales the text
   4x and centres it; a shadow keeps it readable over pale curbs. */
.hud-beat {
  position: fixed;
  inset: 0;
  z-index: 9;
  display: grid;
  place-items: center;
  pointer-events: none;
  font: 700 64px/1 ui-monospace, SFMono-Regular, Menlo, monospace;
  text-shadow: 2px 2px 0 #000;
}
.hud-beat.hold { color: #ffffff; }
.hud-beat.go { color: #7bf59a; }
`;

function injectStyle(): HTMLStyleElement | null {
  if (document.getElementById("hud-style")) return null;
  const style = document.createElement("style");
  style.id = "hud-style";
  style.textContent = CSS;
  document.head.appendChild(style);
  return style;
}

function div(parent: HTMLElement, className: string): HTMLDivElement {
  const el = document.createElement("div");
  el.className = className;
  parent.appendChild(el);
  return el;
}

export function createHud(deps: HudDeps): Hud {
  const { ledger, car, camera } = deps;
  const container = deps.container ?? document.body;

  const style = injectStyle();
  const root = div(container, "hud");
  const cashEl = div(root, "hud-cash");
  const rateEl = div(root, "hud-rate");
  const flashEl = div(root, "hud-flash");
  const debugEl = div(root, "hud-debug");
  const lapsEl = div(root, "hud-laps");
  const beatEl = div(container, "hud-beat");

  const gui = new GUI({ title: "tune" });

  // --- payouts and field ---------------------------------------------------
  // Walked from KNOBS rather than listed here: the Lua's KNOBS table is what
  // makes a new knob a one-line change, and reproducing the list in the panel
  // would give it two places to drift apart.
  const tuneFolder = gui.addFolder("payouts / field");
  /** The knob controllers by key, so a keyboard nudge can refresh its slider. */
  const knobControllers = new Map<keyof Tune, { updateDisplay(): void }>();
  for (const knob of KNOBS) {
    const c = knob.bool
      ? tuneFolder.add(TUNE, knob.key)
      : tuneFolder.add(TUNE, knob.key, knob.min, knob.max, knob.step);
    c.onChange(() => deps.onTuneChange?.(knob.key));
    knobControllers.set(knob.key, c);
  }

  /**
   * `[` / `]` — the ghost count, `endless_dev.lua:37`'s pair with the two keys
   * swapped so `[` adds and `]` removes. Here rather than in `loop.ts` because
   * it is the same act as dragging the `ghosts` slider: mutate `TUNE`, refresh
   * the widget that shows it, and announce the change. `sim/ghosts.ts` re-lays
   * the field off `TUNE.ghosts` on its own, so nothing has to be pushed.
   */
  function nudgeGhosts(delta: number): void {
    const next = Math.max(0, Math.min(MAX_GHOSTS, Math.round(TUNE.ghosts) + delta));
    if (next === TUNE.ghosts) return;
    TUNE.ghosts = next;
    knobControllers.get("ghosts")?.updateDisplay();
    deps.onTuneChange?.("ghosts");
  }

  // --- car: upgrades, then the model's own feel ----------------------------
  // Upgrade levels are a knob, not a ladder (`endless_dev.lua:622`): no cost, no
  // persistence. They write `accel` and `topVel`, which are also editable
  // directly below, so the tuning controllers are refreshed after every apply —
  // otherwise the panel would show the number you typed and the car would be
  // running the one the level implies.
  const carFolder = gui.addFolder("car");
  const upgrades: Upgrades = { ...MID_SPEC };
  const upgradeFolder = carFolder.addFolder("upgrades");
  const applySpec = (): void => {
    applyUpgrades(car, upgrades);
    for (const c of carFolder.controllersRecursive()) c.updateDisplay();
  };
  upgradeFolder.add(upgrades, "accelLevel", 0, 5, 1).onChange(applySpec);
  upgradeFolder.add(upgrades, "topSpeedLevel", 0, 5, 1).onChange(applySpec);
  upgradeFolder.add(upgrades, "driftEnabled").onChange(applySpec);
  upgradeFolder.add(upgrades, "driftBoostEnabled").onChange(applySpec);
  upgradeFolder.add(upgrades, "boostRanks", 0, 5, 1).onChange(applySpec);
  upgradeFolder.add(upgrades, "reverseEnabled").onChange(applySpec);

  // The feel surface `car.ts` deliberately keeps on the instance rather than as
  // module constants. Ranges bracket the authored values generously; the drift
  // pair is the one that matters (see `Car.driftDeccel`).
  carFolder.add(car, "accel", 0, 200, 1);
  carFolder.add(car, "deccel", 0, 400, 5);
  carFolder.add(car, "topVel", 0, 600, 5);
  carFolder.add(car, "turnRateSlow", 0, 6, 0.1);
  carFolder.add(car, "turnRateFast", 0, 6, 0.1);
  carFolder.add(car, "turnRefSpeed", 1, 600, 5);
  carFolder.add(car, "driftTurnRate", 0, 6, 0.1);
  carFolder.add(car, "driftSlide", 0, 1.5, 0.01);
  carFolder.add(car, "driftDeccel", 0, 300, 5);
  carFolder.add(car, "driftDrag", 0, 3, 0.05);
  carFolder.add(car, "driftThreshold", 0, 3, 0.05);
  carFolder.add(car, "boostValue", 0, 500, 10);
  carFolder.close();

  // --- camera --------------------------------------------------------------
  // T7's `ChaseKnobs` as-is: nothing in it is a constant in disguise, and
  // `velBlend` in particular is the live control that re-opens T7's decision if
  // drifts ever read badly (issue #8).
  const camFolder = gui.addFolder("camera");
  camFolder.add(camera, "velBlend", 0, 1, 0.05);
  camFolder.add(camera, "stiffness", 1, 60, 1);
  camFolder.add(camera, "damping", 0.2, 3, 0.05);
  camFolder.add(camera, "distance", 0, 200, 1);
  camFolder.add(camera, "speedPull", 0, 200, 1);
  camFolder.add(camera, "pullLag", 0, 2, 0.05);
  camFolder.add(camera, "height", 0, 400, 1);
  camFolder.add(camera, "lookAhead", 0, 200, 1);
  camFolder.add(camera, "lookHeight", 0, 200, 1);
  camFolder.add(camera, "fov", 30, 120, 1);
  camFolder.add(camera, "velTrustSpeed", 1, 600, 5);
  camFolder.close();

  // --- actions -------------------------------------------------------------
  // Restore-defaults is separate from restart *on purpose*: a restart resets the
  // run and keeps the tuning, this resets the tuning and keeps the run.
  const actions = {
    restoreDefaults(): void {
      restoreDefaults();
      for (const c of tuneFolder.controllers) c.updateDisplay();
      for (const knob of KNOBS) deps.onTuneChange?.(knob.key);
    },
    restartSession(): void {
      deps.onRestart?.();
    },
  };
  gui.add(actions, "restoreDefaults").name("restore authored defaults (0)");
  if (deps.onRestart)
    gui.add(actions, "restartSession").name("restart session (R)");

  let flash: { text: string; up: boolean; until: number } | null = null;
  let visible = true;
  let debugOn = true;
  let lastWall = 0;

  const onKey = (e: KeyboardEvent): void => {
    if (e.code === "Backquote") toggle();
    else if (e.code === "Digit0") actions.restoreDefaults();
    else if (e.code === "BracketLeft") nudgeGhosts(1);
    else if (e.code === "BracketRight") nudgeGhosts(-1);
  };
  window.addEventListener("keydown", onKey);

  // Backtick hides the *instrument*, not the game: the panel and the debug
  // block go, the cash and `$/sec` readout stays. Those two numbers are what the
  // prototype is for, and hiding them is what you do to look at the track with
  // the tuning UI out of the way — not to stop reading the score.
  function toggle(): void {
    visible = !visible;
    debugOn = visible;
    if (visible) gui.show();
    else gui.hide();
  }

  return {
    update(wallSeconds) {
      lastWall = wallSeconds;

      // Cash and the rolling rate are the two numbers worth seeing even with the
      // debug block hidden, so they are never gated on `debugOn`.
      cashEl.textContent = `$${ledger.cash.toFixed(0)}`;
      rateEl.textContent = `$${ledger.rollingRate(TUNE.rateWindow).toFixed(2)}/sec`;

      if (flash && wallSeconds > flash.until) flash = null;
      if (flash) {
        flashEl.textContent = flash.text;
        flashEl.className = `hud-flash ${flash.up ? "up" : "down"}`;
        flashEl.style.opacity = String(
          Math.min(1, (flash.until - wallSeconds) / FLASH_FADE),
        );
      } else {
        flashEl.textContent = "";
      }

      if (!debugOn) {
        debugEl.textContent = "";
        lapsEl.textContent = "";
        return;
      }
      const last = ledger.laps[ledger.laps.length - 1];
      debugEl.textContent =
        `lap ${ledger.lap}  ${ledger.lapTime.toFixed(1)}s   ` +
        `session ${ledger.sessionRate.toFixed(2)}/sec   ` +
        `last lap ${(last?.rate ?? 0).toFixed(2)}/sec\n` +
        `cp $${ledger.cpCash.toFixed(0)} . coins $${ledger.coinCash.toFixed(0)} . hits ${ledger.hits}`;
      lapsEl.textContent = ledger.laps
        .map(
          (l) => `lap ${l.lap}  ${l.t.toFixed(1)}s  $/sec ${l.rate.toFixed(1)}`,
        )
        .join("\n");
    },

    flashRate(delta) {
      flash = {
        text: `${delta >= 0 ? "+" : ""}${delta.toFixed(2)} $/sec`,
        up: delta >= 0,
        until: lastWall + FLASH_TIME,
      };
    },

    setBeat(beat) {
      beatEl.textContent = beat ? beat.text : "";
      beatEl.className = `hud-beat ${beat?.text === "GO" ? "go" : "hold"}`;
      beatEl.style.opacity = String(beat?.alpha ?? 0);
    },

    toggle,

    dispose() {
      window.removeEventListener("keydown", onKey);
      gui.destroy();
      beatEl.remove();
      root.remove();
      style?.remove();
    },
  };
}
