# `sim/` — the pure layer

Everything here is plain TypeScript over plain data: no `three`, no `lil-gui`, no
DOM. Enforced by `no-restricted-imports` in `eslint.config.js`.

The one-way arrow — **`sim/` imports nothing from `render/`** — is what makes this
layer testable in isolation and portable off the browser. Render reads sim state;
it never writes it.

Landed:

- `angle.ts` — `angle.lua`: wrap-safe `normalize` and short-way `lerp`.
- `input.ts` — `CarInput`, the car's input surface as plain data. Held state is
  level, `*Pressed` is an edge that must reach exactly one fixed step.
- `car.ts` — the scalar-speed driving model ported from `car.lua` (T4). Walls are
  not in it: `stepCar` takes a `ResolveMove` callback, and T5 supplies one.
- `collision.ts` — tile lookup, the stepped sweep and the wall bounce (T5),
  filling `car.ts`'s `ResolveMove` seam. One collider per car.
- `tune.ts` — `DEFAULTS` / `TUNE` / `KNOBS` (T8). The sim reads `TUNE`; only the
  HUD writes it. A restart resets the run, never the tuning.
- `cash.ts` — the cash ledger and the `$/sec` arithmetic (T8). Here rather than
  in the HUD because promotion (T9) decides on `lapRate`; the panel only reads.
- `lap.ts` — checkpoints, `rollover()`, promotion by `$/sec`, and the grid-start
  beat (T9). Laps own the beat; ghosts own the line, so `rollover()` calls the
  `GhostLine` seam to install it. The freeze is a gate — `beginStep` returning
  false means the caller steps *nothing*, clocks included.

- `ghosts.ts` — the ghost field (T10): the promoted line, the ghosts laid along
  it by *arc length*, `taken` semantics, and the raw lap recording that
  downsamples to `MIN_SPACING` at promotion. Implements `lap.ts`'s `GhostLine`;
  headings are derived off the polyline here and nowhere else.

Planned inhabitants (see the map, issue #1):

- T12's coin field and the ghost contact test that spends `ghosts.ts`'s `take` /
  `touched` and `lap.ts`'s `graceT`. The last thing `sim/` is waiting on.
