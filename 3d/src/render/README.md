# `render/` — three.js, and only here

Reads sim state, never writes it. All three.js lives at or below this directory
(plus `hud/`, which owns lil-gui).

Inhabitants (see the map, issue #1):

- `scene.ts` — renderer, lights, resize; owns the frame. Holds the chase camera
  but never steps it — `loop.ts` does, on the fixed timestep.
- `track.ts` — track tiles extruded to curb-height boxes, N64 palette,
  checkpoints. Exports `PALETTE`: everything else in here takes its colours from
  there rather than picking new ones. Also the racing-line ribbon — off at
  `lineAlpha` 0, and repointed at the promoted line by `setLine` (T10).
- `kart.ts` — the player kart. Still the crude placeholder; kart geometry is fog.
- `ghosts.ts` — *planned* (T11): the ghost field as translucent parked karts.
- `camera.ts` — the chase cam: a damped spring onto `facingAngle` blended toward
  `velAngle`. Every number in it is a knob, because every number in it is feel.
