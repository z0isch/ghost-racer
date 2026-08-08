# `render/` — three.js, and only here

Reads sim state, never writes it. All three.js lives at or below this directory
(plus `hud/`, which owns lil-gui).

Planned inhabitants (see the map, issue #1):

- `scene.ts` — renderer, lights, resize; owns the frame.
- `track.ts` — track tiles extruded to curb-height boxes, N64 palette.
- `kart.ts` — the player kart.
- `ghosts.ts` — the ghost field as translucent parked karts.
- `camera.ts` — chase cam, damped spring blend toward `vel_angle`.
