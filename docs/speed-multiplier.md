# Design: Speed Multiplier

## Problem

Optimizing a lap stopped feeling rewarding once a player got good at a track.

The cause is structural. Idle income is currently:

```
rate = ghosts * (#events * flat_pay) / period      -- period = best_time + GHOST_LAP_PAUSE
```

(see `lap_cash_rate` / `ghost_cash_rate`, main.lua:377-404)

Lap time only moves the **denominator** (`period`). That's a `K / period` curve with a
hard floor: every track has a theoretically fastest lap, and `rate` asymptotes to
`K / period_min`. Two things compound near that floor and kill the reward:

1. **Asymptote.** As `period -> period_min` the curve flattens; the last second you can
   find is worth far less rate than an early one, and the time increments you can still
   shave shrink faster than the marginal gain rises.
2. **Outpaced by the economy.** Ghosts (max 8), accel, and top_speed are all flat
   multipliers stacked on a growing number, so a +0.05 $/sec PB is invisible against a
   6+ $/sec base — and once those upgrades are maxed, lap time is the _only_ lever left,
   exactly when it's weakest.

## Solution

Make lap time act **multiplicatively on the entire economy**, instead of only shortening
the loop. A single per-track scalar — the speed multiplier — scales _all_ of that track's
income (live checkpoints + every ghost's banking).

Because it multiplies the whole stream, the **absolute** gain from a PB grows as the
player's income grows. A 10%-faster lap is always ~+21% on that track, whether the stream
is worth 1 $/sec or 100 $/sec. Optimization never becomes noise.

### Formula

```lua
speed_mult = clamp((par / best_time) ^ P, 1.0, math.huge)   -- P = 2
```

- `par` — a designer-authored "par time" per track. **This is `1.0x`.**
- `best_time` — the promoted ghost lap (`State.best_time`), recomputed on `promote_run`
  (main.lua:581-586), _not_ the live in-progress lap.
- `P = 2` — the punchiness exponent (chosen; see "Curve" below).
- Clamped to a **minimum of 1.0**: par is break-even. A lap slower than par earns no
  bonus but is never _penalized_ — important for an idle game, where a bad lap shouldn't
  shrink passive income.

`speed_mult` has **no explicit upper cap**. It's naturally bounded because `best_time`
can't drop below the track's physical floor, so `(par / best_time)` tops out on its own.

### Where it applies

`speed_mult` multiplies a track's whole income stream:

```
track_rate = ghosts_t * K_t / period_t * speed_mult_t
```

It multiplies the **coin** stream as well as the **cash** stream. Consequence we want:
"faster lap -> coins are worth more" is satisfied for free, and detouring to grab coins
(which slows the lap) lowers `speed_mult` — making "grab coins" vs "run the clean
checkpoint line" a real route tradeoff.

### Curve (why P = 2)

| lap vs par    | P = 1 | **P = 2** | P = 3 |
| ------------- | ----- | --------- | ----- |
| at par        | 1.00x | 1.00x     | 1.00x |
| 10% under par | 1.11x | **1.23x** | 1.37x |
| 20% under par | 1.25x | **1.56x** | 1.95x |
| ~floor (30%)  | 1.43x | **~2.0x** | ~2.9x |

`P = 2` makes a small PB visibly move a big number without letting the final few percent
of optimization dominate everything (which `P = 3` does and which complicates balancing
track costs). It's the recommended **starting** value — tune from playtests.

## Calibrating `par`

`par` defines the whole bonus range, so it's load-bearing — but it's a playtest value,
not a structural decision. Target:

- Set `par` near a **comfortable early-clear time** for the track.
- Most players then live around **1.2x - 1.6x**.
- A floor-optimal lap reaches **~2.0x**.

Each track ships its own `par`. New tracks therefore hand the player a fresh climb from
1.0x (see `docs/multiple-tracks.md`).

## Presentation

The multiplier is worthless if the player can't see it move — and making it visible is
what converts a 0.3s PB into a moment that feels big.

### HUD badge

Add a third readout to `draw_hud_currencies` (main.lua:807): a hot-colored `x1.85`
"SPEED BONUS" beside the `$/sec` figure. Always on screen, so the player always knows
their economy is riding on lap time.

### Result screen (the heavy lifting)

The result screen already shows time / `$/sec` / `coins/sec` deltas (main.lua:1068-1087).
Add the multiplier as the **headline**:

- Show `x1.82 -> x1.85`, with the number **rolling up** over ~0.5s.
- Below it, the affected `$/sec` recomputing live (`6.40 -> 6.74`).
- The framing goal: a 0.3s PB reads as "my multiplier climbed and my whole income
  jumped," not "+0.05 /sec."

## Implementation order

This can ship on the **current single track first**, before the multi-track restructure:

1. Add `PAR_TIME` constant + `speed_mult` helper computed from `State.best_time`.
2. Thread `speed_mult` into `lap_cash_rate` / `lap_coin_rate` (or the rate aggregation).
3. HUD badge in `draw_hud_currencies`.
4. Result-screen rollup

Then generalize per-track when multiple tracks land.

## Open knobs

- `P` (start 2) — punchiness.
- `par` per track — the bonus range.
