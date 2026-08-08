/**
 * Keyboard -> `CarInput`. The only place the DOM meets the driving model.
 *
 * Bindings mirror the usagi engine's (`meta/usagi.lua:362-364`) so muscle memory
 * carries over from the 2D game, with arrows/WASD on the stick:
 *
 * | action | keys                        |
 * | ------ | --------------------------- |
 * | LEFT   | ArrowLeft, A                |
 * | RIGHT  | ArrowRight, D               |
 * | BTN1   | Z, J  — brake / double-tap flip |
 * | BTN2   | X, K  — handbrake / drift   |
 * | BTN3   | C, L  — spend a boost       |
 *
 * ## Why edges are latched rather than read live
 *
 * The sim runs at a fixed 120Hz while `keydown` arrives on the browser's own
 * schedule, so a frame can contain zero, one, or three fixed steps. If
 * `pressed` simply meant "a keydown landed this frame" it would read true on
 * every step of that frame — two steps at 60Hz, and the manual boost fires
 * twice off one keypress.
 *
 * So a keydown sets a latch, and `takeStep()` — called once per *fixed step* —
 * consumes it. Each physical press therefore reaches exactly one step, whatever
 * the display is doing. Held state needs none of this; it is just level.
 */

import type { CarInput } from "../sim/input.js";

const BINDINGS: Record<string, "left" | "right" | "btn1" | "btn2" | "btn3"> = {
  ArrowLeft: "left",
  KeyA: "left",
  ArrowRight: "right",
  KeyD: "right",
  KeyZ: "btn1",
  KeyJ: "btn1",
  KeyX: "btn2",
  KeyK: "btn2",
  KeyC: "btn3",
  KeyL: "btn3",
};

export interface Keyboard {
  /** Consume input for one fixed step. Edges fire on one step and one only. */
  takeStep(): CarInput;
  dispose(): void;
}

export function createKeyboard(target: EventTarget = window): Keyboard {
  const held = { left: false, right: false, btn1: false, btn2: false, btn3: false };
  let btn1Latched = false;
  let btn3Latched = false;

  const onKeyDown = (e: Event): void => {
    const action = BINDINGS[(e as KeyboardEvent).code];
    if (!action) return;
    e.preventDefault();
    // Auto-repeat is a held key, not a new press: latching on it would machine
    // gun the boost at the OS repeat rate.
    if ((e as KeyboardEvent).repeat) return;
    held[action] = true;
    if (action === "btn1") btn1Latched = true;
    if (action === "btn3") btn3Latched = true;
  };

  const onKeyUp = (e: Event): void => {
    const action = BINDINGS[(e as KeyboardEvent).code];
    if (!action) return;
    e.preventDefault();
    held[action] = false;
  };

  // Focus loss never delivers keyup, which would otherwise leave the throttle
  // steering into a wall while the player is in another tab.
  const onBlur = (): void => {
    held.left = held.right = held.btn1 = held.btn2 = held.btn3 = false;
  };

  target.addEventListener("keydown", onKeyDown);
  target.addEventListener("keyup", onKeyUp);
  window.addEventListener("blur", onBlur);

  return {
    takeStep() {
      const input: CarInput = {
        left: held.left,
        right: held.right,
        brake: held.btn1,
        brakePressed: btn1Latched,
        drift: held.btn2,
        boostPressed: btn3Latched,
      };
      btn1Latched = false;
      btn3Latched = false;
      return input;
    },
    dispose() {
      target.removeEventListener("keydown", onKeyDown);
      target.removeEventListener("keyup", onKeyUp);
      window.removeEventListener("blur", onBlur);
    },
  };
}
