# Design: Multiple Tracks

## Why

The speed multiplier (`docs/speed-multiplier.md`) makes optimizing a lap feel rewarding,
but on a single track that reward **mathematically must die** near the lap-time floor:
there's a fastest-possible lap, and any function of lap time flattens as you approach it.

Multiple tracks are the fix for that ceiling. Each new track is a fresh optimization
surface that resets the climb from `1.0x`, and — because tracks earn in parallel — a new
parallel income stream. Optimization stays meaningful forever because there's always a
track that isn't yet near its floor.

## Idle model: parallel income

Every **unlocked** track earns **simultaneously** into one shared wallet. Total idle:

```
total_rate = sum over owned tracks of:
  ghosts_t * K_t / period_t * speed_mult_t
```

- `K_t` — that track's numerator (its checkpoints + active coins * their pays).
- `period_t` — that track's best lap + `GHOST_LAP_PAUSE`.
- `speed_mult_t` — that track's speed multiplier (`docs/speed-multiplier.md`).

This is the classic idle "generators" structure: unlocking a track **compounds** income
rather than swapping it, which is what satisfies the "keep the economy growing" goal.
Optimizing an *old* track still pays, via its own `speed_mult_t`.

Per-frame, the ghost sim (`update_ghost_earnings`, main.lua:648) must loop **every owned
track's** `ghost_line`, not just one.

## State restructure

Today `State` holds a single implicit track (`ghost_line`, `best_time`, ghost count;
main.lua:247-257). Split state into **global** and **per-track**.

### Global

- `money`, `coins` — shared wallets.
- `accel`, `top_speed` — these are the **car**, not the track; the upgrade applies on
  whichever track you race. Their *effect* is global, but *purchasing* them is
  track-gated: `accel` is only buyable on Track 1 (`basic`), `top_speed` only on
  Track 2 (`track2`). Each track declares the items its shop offers — along with
  each item's cost/scaling (`currency`, `max`, `base_cost`, `growth`) — in its
  `shop` list in `TRACKS` (`ghosts`/`coins` are repeated per track, so their
  cost/scaling is duplicated). There is no global upgrade table. (Coins/moves are
  global too — see "Coins" below.)
- `unlocked` — which tracks the player owns.
- `active_track` — the tab currently selected (UI state, see "Navigation").

### Per-track

Each track carries its own:

- `ghost_line` — recorded best lap (the looping ghost).
- `best_time` — drives `speed_mult_t` and `period_t`.
- `par` — the `1.0x` reference for `speed_mult_t`.
- `ghosts` — **per-track** ghost count (see "Per-track ghost investment").
- coin placements / `coins` unlock level — coins are authored per track.
- checkpoints — authored per track.

A sketch:

```lua
State = {
  money = 0,
  coins = 0,
  accel = 0,
  top_speed = 0,
  active_track = "basic",
  tracks = {
    basic = { ghost_line = ..., best_time = ..., par = 20.0, ghosts = 0, coins = 0 },
    -- track2 = { ... },
  },
}
```

`save_game` / `_init` (main.lua:265-295) must persist and clamp-load this nested shape.
Note the save constraint: integer-keyed maps aren't allowed, so key `tracks` by **string
track ids** (USAGI.md: `usagi.save` key rules).

## Per-track ghost investment

Ghosts are bought **per track**, not as one global count. "Which track deserves capital"
is the core idle-management decision: a track with a high `speed_mult` and short `period`
is worth more ghosts.

- Each track has its own geometric ghost cost curve (reuse `upgrade_cost`, main.lua:304,
  keyed per track).
- Keep the existing "first ghost free" rule per track (main.lua:308).
- Buying a ghost only affects that track's stream; reset that track's `ghost_prev_phase`
  on purchase (main.lua:949) to avoid spurious crossings.

## Unlocking tracks: cash purchase

New tracks are bought with **cash**, on a geometric cost curve (same shape as existing
upgrades). No skill wall:

- Idle income funds expansion, keeping the economy loop as the pacer.
- A player is never hard-walled by an unreachable time.
- Optimization doesn't *gate* content — its reward is purely economic (the speed bonus
  and a shorter period), which is the chosen primary reward role.

Buying a track seeds its per-track state (empty `ghost_line`, its authored `par`,
`ghosts = 0`). The track produces no idle income until the player races it once and
promotes a `ghost_line`.

## Coins (unchanged)

Coins are **not** part of this system. They're a discrete move tree (drift -> boosted
drift -> ...), placeholder today as accel/top_speed. They're left as-is. The relevant
interaction: because `speed_mult` is keyed to lap *time*, a coin-grab detour slows the
lap and lowers the cash multiplier — so per track, "optimize the coin line" and "optimize
the checkpoint line" are different strategies. That tradeoff is emergent and wanted.

## Navigation: tabbed single shop

Keep one shop. Tabs / arrows switch the `active_track` that the shop **and** the RACE
button apply to (vs. today's single flat shop, `draw_buy_shop`, main.lua:957).

Because only one track's detail is visible at a time, the parallel-income overview must be
surfaced explicitly or per-track ghost investment becomes guesswork:

- Show each track's **`$/sec` contribution** on its tab.
- Show a **persistent global total `$/sec`** somewhere always-visible.
- Show the active track's `speed_mult` badge (shared with the HUD design).

```
< Track 2 >    x1.20    (this track 1.90/s)      TOTAL 8.64/s
  Ghosts  [+]   Accel ...   (active track's shop)
  [ RACE THIS TRACK ]
[ Buy Track 3 - $5,000 ]
```

## Track authoring

There's a Tiled pipeline already (`tile-map/basic.tmx -> basic.lua`, plus `.tsx` /
`.tiled-project`). Adding tracks means:

1. Author a new `.tmx` -> export a new `<name>.lua` map module.
2. Generalize the **hardcoded single-track wiring** in main.lua, which currently bakes in
   `basic`: the `require` (main.lua:1), `map_layer` / `map_width` / `map_height`
   (main.lua:8-11), `SPAWN_TILE` (main.lua:30), `CHECKPOINTS` (main.lua:78-81), and
   `COINS` (main.lua:86-90) all assume the one map. These must become per-track data
   selected by `active_track`.

## Implementation order

1. **Ship the speed multiplier on the current single track first**
   (`docs/speed-multiplier.md`) — no restructure needed.
2. Restructure `State` into global + `tracks[id]` (with one track: `basic`). Keep behavior
   identical; this is a refactor.
3. Generalize the hardcoded map/checkpoint/coin/spawn wiring to read from the active
   track.
4. Add the tabbed navigation + per-track `$/sec` + global total.
5. Add the parallel ghost sim (loop every owned track's `ghost_line` in
   `update_ghost_earnings`).
6. Add cash-purchase track unlocking + a second authored track.

## Open knobs

- Track unlock cost curve (base + growth), tuned against idle income.
- How many tracks at launch / authoring throughput.
- `par` per track (see `docs/speed-multiplier.md`).
```