# `io/` — the data boundary

- `types.ts` — the track-export schema shared by the Lua exporter and the 3D side.
- `trackData.ts` — loading and validating exported track JSON.

The exporter itself lands at the repo root (it reads `track_data.lua`), and is
kept re-runnable: the 3D side will discover fields the first export dropped.
