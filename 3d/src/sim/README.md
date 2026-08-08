# `sim/` — the pure layer

Everything here is plain TypeScript over plain data: no `three`, no `lil-gui`, no
DOM. Enforced by `no-restricted-imports` in `eslint.config.js`.

The one-way arrow — **`sim/` imports nothing from `render/`** — is what makes this
layer testable in isolation and portable off the browser. Render reads sim state;
it never writes it.

Planned inhabitants (see the map, issue #1):

- `car.ts` — the scalar-speed driving model ported from `car.lua`.
- `collision.ts` — tile-grid lookup, stepped movement, wall bounce.
- `ghosts.ts` — the ghost field: layout by distance, `taken` semantics.
- `lap.ts` — checkpoints, `rollover()`, promotion by `$/sec`. Laps own the beat;
  ghosts own the line, so `rollover()` calls into `ghosts.ts` to install it.
- `tune.ts` — the `TUNE` / `DEFAULTS` / `KNOBS` structure.
