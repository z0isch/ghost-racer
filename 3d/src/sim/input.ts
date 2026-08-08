/**
 * The car's input surface, as plain data.
 *
 * `sim/` never touches the keyboard: one fixed step consumes one of these and
 * nothing else. That is what lets a recorded lap or a test drive the same model
 * the player does — you hand `stepCar` a struct, not a device.
 *
 * `car.lua` reads `input.held` and `input.pressed` mid-update; the split is kept
 * because the flip's double-tap and the manual boost are edge-triggered while
 * steering, braking and drift are level-triggered. **`*Pressed` must be true for
 * exactly one fixed step**, not for every step of the frame that saw the
 * keydown — at 120Hz against a 60Hz display that would fire a boost twice.
 * `io/keyboard.ts` is what guarantees that.
 */
export interface CarInput {
  /** input.LEFT held. */
  readonly left: boolean;
  /** input.RIGHT held. */
  readonly right: boolean;
  /** BTN1 held — the brake. Note the throttle has no button; it is always on. */
  readonly brake: boolean;
  /** BTN1 edge. Two inside FLIP_TAP_WINDOW start a flip. */
  readonly brakePressed: boolean;
  /** BTN2 held — the handbrake / drift. */
  readonly drift: boolean;
  /** BTN3 edge — spend a stored boost. */
  readonly boostPressed: boolean;
}

export const NO_INPUT: CarInput = {
  left: false,
  right: false,
  brake: false,
  brakePressed: false,
  drift: false,
  boostPressed: false,
};
