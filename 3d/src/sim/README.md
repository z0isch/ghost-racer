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

Planned inhabitants (see the map, issue #1):

- `collision.ts` — tile-grid lookup, stepped movement, wall bounce. Plugs into
  `car.ts`'s `ResolveMove` seam.
- `ghosts.ts` — the ghost field: layout by distance, `taken` semantics.
- `lap.ts` — checkpoints, `rollover()`, promotion by `$/sec`. Laps own the beat;
  ghosts own the line, so `rollover()` calls into `ghosts.ts` to install it.
- `tune.ts` — the `TUNE` / `DEFAULTS` / `KNOBS` structure.
