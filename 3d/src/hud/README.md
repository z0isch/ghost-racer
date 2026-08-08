# `hud/` — knobs and instruments

`hud.ts` mirrors the `TUNE` / `DEFAULTS` / `KNOBS` structure from
`endless_dev.lua:96-138` into lil-gui, including a restore-authored-defaults
control, and reads out `$/sec` (rolling, session, last lap, per-lap history).

The HUD is the only instrument this prototype has — it goes in early, not last.
