# `render/` — three.js, and only here

Reads sim state, never writes it. All three.js lives at or below this directory
(plus `hud/`, which owns lil-gui).

Inhabitants (see the map, issue #1):

- `scene.ts` — renderer, lights, resize; owns the frame. Its camera is a
  deliberately dumb overhead follow cam until T7.
- `track.ts` — track tiles extruded to curb-height boxes, N64 palette,
  checkpoints. Exports `PALETTE`: everything else in here takes its colours from
  there rather than picking new ones.
- `kart.ts` — the player kart. Still the crude placeholder; kart geometry is fog.
- `ghosts.ts` — *planned* (T11): the ghost field as translucent parked karts.
- `camera.ts` — *planned* (T7): chase cam, damped spring blend toward `vel_angle`.
