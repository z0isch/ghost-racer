# 3D Kart Prototype — Design Agreement

Status: agreed, not started. Derived from a grilling session over `endless_dev.lua`
on 2026-08-07. Every line below is a settled decision, not a suggestion; the
"Open risks" section at the end records the things we knowingly accepted rather
than resolved.

## What it is

A **new, separate game**. It is not a port of the usagi title and does not carry
that game's economy, rebirth loop, skill tree, or rank ladder. It steals exactly
one idea from `endless_dev.lua` and inverts it.

In `endless_dev.lua`, ghosts of your previous lap are **head-on hazards you
dodge**. Here they are **stationary, and you drive into them** for a boost and a
payout. Because they are laid out along your own promoted best lap, the game
becomes a **groove game**: retrace your own line precisely and you collect
everything, which makes the next lap faster, which promotes a faster line.

That flywheel has no counter-pressure, deliberately. The groove is the game.

It is a **prototype/harness**, in the same spirit as this repo's `*_dev.lua`
files: live-tunable knobs, a restore-defaults control, no persistence, no save.

## Stack

- Vite + TypeScript + three.js + lil-gui.
- Lives in a **subdirectory of `usagi-test`**, so the track exporter sits next to
  the Lua it reads. Split into its own repo only if the prototype graduates.
- Deploys as static files (browser is the target; itch-style instant play).
- lil-gui mirrors the `TUNE` / `DEFAULTS` / `KNOBS` structure from
  `endless_dev.lua:96-138`, including a restore-authored-defaults control.
- **Fixed 120Hz timestep accumulator**, interpolated render. Non-negotiable: the
  entire output of this harness is numbers compared between laps, and raw
  `requestAnimationFrame` deltas vary by display refresh rate, which would make
  the same driving produce different lap times on different machines and replay
  a 144Hz-recorded ghost incorrectly at 60Hz.
- No physics library. Rapier/cannon-es would be the fastest way to make this stop
  feeling like the 2D game.

## What ports verbatim

### Driving model — `car.lua`

`car.lua` is not a physics-engine car. It is a scalar-speed model:

- one `vel` scalar,
- `facing_angle` (where the kart points) and `vel_angle` (where it actually
  travels) tracked separately,
- drift as a third angle offset (`drift_slide`, `drift_dir`),
- boosts as impulses along the current travel direction (`car.lua:171-178`),
  clamped to `top_vel + OVERSPEED_MAX`.

Roughly 250 of its 573 lines are that model; the remainder is `gfx`/`sfx` draw
code (headlights, taillights, flames, skid marks) which is discarded. The model
is plane-only by construction, so the port is `(x, y)` -> `(x, z)` and nothing
else. Expect about a day of work.

### Collision — `car.lua:22-30`

Tile-grid lookup against the map, stepped movement via `MAX_MOVE_STEP` so a fast
car cannot tunnel a tile in one frame, plus the wall bounce constants
(`WALL_DECEL`, `WALL_RESTITUTION`, `WALL_LOSS_FACTOR`, `MIN_BOUNCE_VEL`,
`BOUNCE_DECAY`). Ported exactly. O(1), and it guarantees the wall feel matches
the 2D game bit for bit. Wall *visual* height is independent of this, since
collision is a 2D tile test.

Walls are load-bearing for the design: without them, every detour off the line is
free and the routing decision evaporates.

### Ghost and line machinery — `endless_dev.lua`, `ghost.lua`

All pure 2D polyline math, survives untouched:

- `ghost.sample_at` — lerp over `{t, x, y, angle}` records.
- `time_at_dist` (`endless_dev.lua:272`) — arc length to phase.
- `set_offsets` (`endless_dev.lua:297`) — lays the field out by **distance**
  along the line, not time, so spacing is even in space rather than clumping in
  corners. Includes the `START_GAP_LENGTHS` (3 car lengths) gap carved off both
  ends of the loop.
- `set_line` (`endless_dev.lua:312`) — installs a line and rebuilds its
  cumulative-distance table.
- `rollover` (`endless_dev.lua:451`) — promote-if-better-`$/sec`, lap history,
  state reset.
- `State.taken` semantics (`endless_dev.lua:434-437`) — one hit per ghost per
  lap; a hit ghost drops out of both contact and draw until rollover.
- The `COUNT_HOLD` / `COUNT_GO` "1 / GO" beat.
- The debug HUD: rolling `$/sec` over `rate_window`, session rate, last-lap rate,
  per-lap history (`endless_dev.lua:773-788`). **Port this early, not last** — it
  is the only instrument this prototype has.

## Decisions

| Area | Decision |
| --- | --- |
| Genre framing | 3D visuals over the existing 2D driving model. Not real 3D physics, not Mode-7. |
| Camera | Full chase cam behind the kart, Diddy Kong Racing-faithful. |
| Camera anchor | Damped spring blend toward `vel_angle` (not `facing_angle`), with blend weight and spring stiffness as knobs. |
| Art direction | N64-era low-poly, flat-shaded, bright saturated palette. |
| Wall height | Curb height — ankle-high barriers, open sightlines. |
| Pickup appearance | Translucent **parked karts**. The ghost fiction is kept. |
| Pickup behaviour | One hit each per lap (`taken`), whole field restored at rollover. |
| Racing line | **Not rendered.** |
| Telegraphing | **None.** No minimap, no chevrons, no proximity audio. Pure memory. |
| Cash sources | All three: checkpoints (`cp_pay`), the authored coin field (`coin_pay`), and ghost hits (`boost_pay`). |
| Promotion rule | `$/sec`, mechanism verbatim from `rollover()`. |
| Lap boundary | **Grid-start reset kept** — car teleports to spawn, velocity zeroed, boosts refilled, world frozen for the "1" beat. This is a lap-based game with a hard beat at the line. |
| Audio | None. |
| Tracks | track3 only. No `T` cycling. |
| Progression | None. No persist, no rebirth, no skill tree. |
| Upgrades | Exposed as knobs only (`car.apply_upgrades`, cf. `endless_dev.lua:622`). |

### Why camera anchor matters most

The drift model is the most heavily tuned thing in `car.lua`. During a drift the
kart points one way and travels another. A camera locked to `facing_angle` puts
the corner exit off-screen; a camera locked hard to `vel_angle` snaps. The damped
blend is the standard answer, and getting it wrong will read as "the physics
broke in 3D" when nothing broke but the view.

### Why upgrades stay as knobs

Top speed is the variable most likely to break this design. A chain of pickups
spaced for a 220 px/s car is a different routing problem at 320 — and since
collecting pickups *raises* speed, the game walks up that curve on its own.

## Pipeline

### Track export

A one-off Lua script exports track3 from `track_data.lua` to JSON:

- tile map (extruded to curb-height boxes in three.js),
- checkpoints,
- spawn tile and authored facing,
- coin slots,
- **plus `data/ref_track3.json`**, the captured human reference lap.

Seeding from the reference lap is required, not optional: `ideal_line()`
(`endless_dev.lua:237-245`) already does this in 2D, and with telegraphing set to
*none*, a blind first lap would mean hunting invisible pickups on an unlearned
track. Run one must have a plausible chain already in place.

Keep the exporter in-tree and re-runnable — it will need re-running as the 3D
side discovers fields the first export dropped.

### Lap recording

**Raw per sim step during the lap; downsampled once at promotion** to the 6px
`MIN_SPACING` polyline format that `reference.lua:23` already produces, keeping
each retained point's original timestamp.

This matters more than it did in 2D. The promoted line and the seeded reference
line must share one format, or ghost facing angles will jitter differently
depending on which source a ghost came from — `HEADING_DT`
(`endless_dev.lua:56`) exists precisely to paper over lerp noise between
downsampled points, and it is calibrated against one resolution, not two.

At 120Hz a 40-second lap is ~4,800 raw points; downsampling at promotion keeps
in-lap fidelity while paying the cost once per rollover.

## Open risks

Recorded as accepted, not as objections to re-argue.

1. **Legibility stack.** Chase cam + no rendered line + no telegraphing +
   kart-shaped pickups compound. The player cannot see where the chain goes, and
   the targets are shaped like obstacles, which invites an instinctive swerve
   away from the thing you want them to hit. If the `$/sec` curve plateaus after
   a handful of laps, this is the first thing to revisit — cheapest lever is a
   minimap, then a ground ribbon for the promoted line (`line_alpha` already
   exists, defaulted to 0 at `endless_dev.lua:107`).

2. **Payout ratio is inverted for this design.** Authored defaults are
   `boost_pay = 5` against `coin_pay = 25` and `cp_pay = 45`, so pickups are
   near-worthless as income — in a game whose entire premise is collecting them.
   That ratio is the primary tuning knob on day one. Keeping all three cash
   sources also means the coin field is a second, competing route that pulls the
   player off the chain, and checkpoint payouts are a flat time-based drip that
   dilutes the `$/sec` signal being steered by.

3. **Grid-start reset versus "never stop driving."** `endless_dev.lua`'s premise
   is a loop you never stop driving; keeping the per-lap teleport-and-freeze
   makes this a lap-based game with a hard rupture at the line, which reads
   larger from a chase cam than from top-down. Consistent and intentional, but
   named here.

4. **Success criterion deliberately left unspecified.** No agreed observable for
   "this worked." The debug HUD goes in early regardless.

## Explicitly out of scope

Rebirth, the skill tree, persistence, saves, the rank ladder, multiple tracks,
track cycling, audio, weapons/items, AI opponents, elevation, jumps, banked
corners, any real 3D vehicle physics.
