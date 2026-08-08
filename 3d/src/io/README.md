# `io/` — the data boundary

- `types.ts` — the track-export schema shared by the Lua exporter and the 3D side.
- `keyboard.ts` — keyboard to `sim/input.ts`'s `CarInput`. Here rather than in
  `sim/` because it touches the DOM; it also latches edge-triggered buttons so a
  press reaches exactly one fixed step regardless of display refresh rate.
- `trackData.ts` — loads and validates `3d/data/track3.json`, and is the one
  place grid units become source pixels (`checkpointRect` / `coinRect`).
  Exports `track3`, validated at module load.

The exporter itself lands at the repo root — `export_track_3d.lua`, which reads
`track_data.lua` — and is kept re-runnable: the 3D side will discover fields the
first export dropped. Re-run it with plain Lua from the repo root:

```
lua export_track_3d.lua
```

Both ends check the same two invariants (tile ids `types.ts` knows about, and a
reference lap that starts at the spawn corner), so a stale or hand-edited export
fails at boot with the field that disagreed rather than one `undefined` at a
time inside collision.
