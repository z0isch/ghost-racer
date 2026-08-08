# `hud/` — knobs and instruments

`hud.ts` is the prototype's only instrument, landed early rather than last (T8,
issue #9).

- **Knobs**: `sim/tune.ts`'s `KNOBS` walked into lil-gui, plus the car's live
  tuning, its upgrade levels (`applyUpgrades` — a knob, not a ladder), and T7's
  `ChaseKnobs` wired in as-is. Restore-authored-defaults is a panel button and
  the `0` key; backtick toggles the whole HUD.
- **Readout**: cash and rolling `$/sec` always on, and a debug block with the
  session rate, last-lap rate, tallies and the last five laps. `flashRate(delta)`
  is the post-rollover comparison, for T9's `rollover()` to call.

The HUD holds no state anything else could want: tuning lives in `sim/tune.ts`,
money in `sim/cash.ts`, camera feel in `render/camera.ts`. It binds widgets to
them and formats numbers — which is why a new knob is one entry in `KNOBS` and
nothing here.
