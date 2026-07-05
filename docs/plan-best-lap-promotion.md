# Plan: Best-lap promotion (replace "never lose rank")

## Context

Commit `e120a42` ("Never lose rank") made `best_rate` a high-water mark so a
track's rank multiplier never drops, but `ghost.promote()` still overwrites
`ghost_line` with the *latest* lap — so a sloppy lap can still lower ghost
income, and the race result screen needed careful "sticky rank" display logic
to stay honest about that asymmetry.

**New design:** only promote a lap that beats the stored best `$/sec`. The
ghost line and its rate then always move together and only improve, rank
monotonicity falls out for free, and the whole result screen is deleted in
favor of a short finish beat plus modals in the buy scene.

## Agreed decisions (do not re-litigate)

1. **Gate metric:** `run_rate` (`raw_earned / race.time`) — the same metric
   rank thresholds are defined on. Promote iff `run_rate > tstate.best_rate`
   (strictly greater; ties keep the old ghost). First lap always promotes
   (`best_rate` is `nil`).
2. **Field name:** keep `best_rate`. It now literally means "the stored best
   lap's $/sec". `a_rank_earned` stays derived from it. No save-format
   compatibility needed (game is unreleased).
3. **Result screen:** deleted entirely, for every finish. After crossing the
   final checkpoint there is a ~1 second "finished" beat (world still drawn,
   controls dead, no dim/overlay) so the last payout popup and sfx land, then
   the game auto-promotes-if-better, saves, and goes to the buy scene.
4. **Announcements:** modals in the buy scene, one modal per race maximum:
   - Fires when the promoted lap's rank exceeds the previous rank, **and**
     always after the very first lap on a track (even at rank D).
   - When the same lap also makes the next track purchasable (first time
     hitting A/S), the unlock line is appended to the *same* modal — never
     two queued modals.
   - A promoted lap with no rank change is silent (the rank letter and rates
     on the buy screen are the feedback).
5. **Modal copy:** rank-up modal title is the new rank (e.g. `RANK A!`), body
   shows the Your Rate / Ghost Rate pay changes (Ghost Rate line only if the
   track has ghosts). First-lap modal title has no `!` and the body is the
   "beat your lap" explainer. See exact strings below.
6. **No new HUD elements.** The live rank letter and the pace ghost already
   give mid-race comparison.
7. **Keep** the unrelated tuning already in the tree/history: drift prices,
   `GHOST_RACE_ALPHA = 0.1`, and the uncommitted `scenes/buy.lua` modal-text
   edits (they already say "your best lap").

---

## Step 1 — `ghost.lua`: conditional promote

Replace the whole `M.promote()` function (currently near line 212) with:

```lua
-- Stores the finished run as the track's ghost lap, but only if it beats the
-- stored best $/sec - a worse lap leaves the ghost (and therefore the rank)
-- untouched. Returns true when the lap was promoted.
function M.promote()
  local id     = State.active_track
  local tstate = State.tracks[id]
  if tstate.best_rate and State.race.run_rate <= tstate.best_rate then
    return false
  end
  tstate.ghost_line = State.race.recording
  tstate.best_rate  = State.race.run_rate
  M.rebuild_sim(id)
  return true
end
```

Note: `State.race.run_rate` must be set before calling this (Step 3 does so).

## Step 2 — `economy.lua`: comment updates only

No behavior changes. `player_pay`, `track_cash_rate`, `bank`, `a_rank_earned`
already read `tstate.best_rate` and stay as-is.

Update the comment above `M.track_rank` (near line 85) from:

```lua
-- Rank of the established (high-water) rate stored for a track. Never drops
-- once earned, even if a later lap is slower - see ghost.promote().
```

to:

```lua
-- Rank of the best promoted lap stored for a track. Only better laps are
-- promoted (see ghost.promote()), so this never drops.
```

## Step 3 — `scenes/race.lua`: delete the result screen, add the finish beat

This file loses ~140 lines. Work through the sub-steps in order.

### 3a. Constants and helpers

- Add below `local GHOST_RACE_ALPHA = 0.1`:

  ```lua
  local FINISH_BEAT_SECS = 1.0
  ```

- Delete the `round2` helper (line 17) — nothing uses it after this change.

### 3b. `M.enter()` — drop dead race fields

`race.earned` is no longer read anywhere; remove it. New `State.race` table:

```lua
  State.race = {
    next_checkpoint = 1,
    time            = 0,
    phase           = State.seen_help and "countdown" or "help",
    raw_earned      = 0,
    coins_collected = {},
    first_race      = not State.seen_help,
  }
```

### 3c. Replace `finish_race()` entirely

Delete the current `finish_race` (lines 63–98) and replace with:

```lua
local function finish_race()
  local race     = State.race
  local id       = State.active_track
  local tstate   = State.tracks[id]

  race.run_rate  = race.time > 0 and (race.raw_earned / race.time) or 0
  race.phase     = "finished"
  race.beat_left = FINISH_BEAT_SECS

  local first_lap = tstate.ghost_line == nil
  local prev_rank = economy.track_rank(id)
  ghost.promote()
  local new_rank  = economy.track_rank(id)

  if first_lap or new_rank ~= prev_rank then
    local was_a_or_s  = prev_rank == "A" or prev_rank == "S"
    local is_a_or_s   = new_rank == "A" or new_rank == "S"
    local show_unlock = false
    if is_a_or_s and not was_a_or_s then
      local idx     = track_data.get_track_index(id)
      local next_id = track_data.TRACK_ORDER[idx + 1]
      show_unlock   = next_id ~= nil and not State.unlocked[next_id]
    end
    State.race_modal = {
      track_id    = id,
      rank        = new_rank,
      -- nil on the first lap: the modal then shows the explainer body
      -- instead of rate deltas.
      prev_rank   = not first_lap and prev_rank or nil,
      show_unlock = show_unlock,
    }
  end

  persist.save()
end
```

Notes for the implementer:

- `prev_rank` is captured *before* `ghost.promote()` and `new_rank` after —
  the rank can only change when the lap was actually promoted, so no separate
  "promoted" flag is needed for the modal decision.
- `State.race_modal` is intentionally transient (not part of
  `progression_of_state()` in `persist.lua`), so it is not saved. Do not add
  it to the save file.
- All the old fields (`run_time`, `has_baseline`, `run_cash_rate`,
  `run_rank`, `result_start_time`, `new_rank`, `rank_up`,
  `ghost_total_rate`, `run_total_rate`, `show_track_unlock_msg`) are gone.

### 3d. `M.update(dt)` — handle the `"finished"` phase

Add a new branch to the phase chain, after the `"countdown"` branch and
before the `"racing"` branch:

```lua
  elseif race.phase == "finished" then
    race.beat_left = race.beat_left - dt
    if race.beat_left <= 0 then
      SceneGoto("buy")
    end
```

Nothing else in `update` changes: `ghost.update`/`economy.bank` at the top
keep running during the beat (income ghosts keep banking), `car.update` is
not called (controls dead, car frozen), and `popups.update(dt)` at the bottom
lets the final payout popup play out.

### 3e. `M.draw()` — delete the result rendering

- Delete the functions `draw_total_rate_line` (lines 181–201) and
  `draw_race_result` (lines 203–296) entirely.
- In `M.draw()`, the checkpoint loop is guarded by
  `if race.phase ~= "result" then`. Change the guard to
  `if race.phase ~= "finished" then` (all checkpoints are crossed by then, so
  this is just keeping the old intent: no checkpoint UI after the finish).
- Replace the phase dispatch at the bottom:

  ```lua
  if race.phase == "help" then
    draw_help()
  elseif race.phase == "countdown" then
    draw_countdown()
  elseif race.phase == "racing" then
    if not race.first_race then
      if ui.button("QUIT", 5, 5, { w = 50 }) then
        persist.save()
        SceneGoto("buy")
      end
    end
    local hw = usagi.measure_text(get_hints())
    local hx = usagi.GAME_W - hw
    gfx.text_ex(get_hints(), hx, 0, 1, 0, gfx.COLOR_LIGHT_GRAY, 1)
  end
  ```

  (i.e. the old `elseif race.phase == "result"` branch is gone, and the old
  final `else` branch is now explicitly the `"racing"` branch; the
  `"finished"` phase draws nothing extra — just the world.)
- If `dim` and `modal` requires at the top of the file are now unused
  (`dim` was only used by the deleted result screen; `modal` only by
  `draw_help`— **check before removing**: `draw_help` uses `modal.draw`, so
  keep `modal`; remove the `dim` require only if no remaining call uses it).

## Step 4 — `scenes/buy.lua`: the post-race modal

### 4a. Dismissal, in `M.update(dt)`

Mirror the `purchase_modal` pattern. After the existing `purchase_modal`
block add:

```lua
  if State.race_modal and input.pressed(input.BTN1) then
    State.race_modal = nil
  end
```

### 4b. Drawing priority, in `M.draw()`

Replace:

```lua
  if State.purchase_modal then
    M.draw_purchase_modal()
  else
    M.draw_shop()
  end
```

with:

```lua
  if State.race_modal then
    M.draw_race_modal()
  elseif State.purchase_modal then
    M.draw_purchase_modal()
  else
    M.draw_shop()
  end
```

### 4c. New function `M.draw_race_modal()`

Add next to `M.draw_purchase_modal`:

```lua
-- Post-race modal: shown after the very first lap on a track (explains the
-- beat-your-lap loop) and after any lap that raised the track's rank (shows
-- the pay-rate changes). See scenes/race.lua finish_race().
function M.draw_race_modal()
  local info  = State.race_modal
  local id    = info.track_id
  local title = "RANK " .. info.rank .. (info.prev_rank and "!" or "")

  local body
  if info.prev_rank then
    local prev_mult = economy.RANK_MULTS[info.prev_rank]
    local new_mult  = economy.RANK_MULTS[info.rank]
    body            = string.format("Your Rate:  $%d -> $%d",
      economy.pay_for_mult(id, prev_mult), economy.pay_for_mult(id, new_mult))
    if State.tracks[id].ghosts > 0 then
      local pay = economy.track_pay(id)
      body = body .. string.format("\nGhost Rate: $%d -> $%d",
        math.floor(pay * prev_mult + 0.5), math.floor(pay * new_mult + 0.5))
    end
  else
    body = "Lap saved! Beat it to raise\nyour rank and pay rates."
  end

  if info.show_unlock then
    body = body .. "\n\nNew track available in the shop!"
  end

  if modal.draw({ title = title, body = body }) then
    State.race_modal = nil
  end
end
```

Notes:

- The `math.floor(... + 0.5)` around the ghost-rate values is required, not
  cosmetic: rank mults like `0.6` are not exact in binary floating point
  (`5 * 0.6 == 3.0000000000000004`), and `string.format("%d", ...)` in Lua
  5.3+ raises "number has no integer representation" on such values. (The old
  result screen had this same latent bug.)
- Title/body render in the modal's fixed white/gray; the rank letter is not
  colored here. That is accepted.

## Step 5 — `persist.lua`: trim the default race table

In `default_state()`, the `race` table only exists so HUD/state checks don't
nil-crash before the first race. Remove the dead `earned` field:

```lua
    race         = {
      next_checkpoint = 1,
      time            = 0,
      phase           = "countdown",
      coins_collected = {},
    },
```

No changes to `progression_of_state` / `apply_progression` — `best_rate` is
already the only per-track rate field.

## Step 6 — sanity greps (must all come back empty)

```
grep -rn "run_total_rate\|ghost_total_rate\|run_cash_rate\|has_baseline\|result_start_time\|show_track_unlock_msg\|rank_up\|run_mult\|ghost_mult" *.lua scenes/
grep -rn "race.earned\|\"result\"" *.lua scenes/
grep -rn "round2" scenes/
```

Also confirm `race.run_rank`, `race.prev_rank`, `race.new_rank` no longer
appear in `scenes/race.lua` (they moved into `State.race_modal`).

## Step 7 — verify by playing

Run the game with `usagi dev .` from the repo root (live reload) and check,
in order. `persist.dev_save_snapshot` / `dev_load_snapshot` (see
`persist.lua`) and hand-editing `data/dev_snapshot.json` can fast-forward
state (e.g. set `money`, `tracks.track1.best_rate`) instead of grinding.

1. **First lap on a fresh save:** finish a lap → ~1s beat where the car
   freezes and the last `$` popup plays → buy scene shows a modal titled
   `RANK <letter>` (no `!`) with the "Lap saved!" body. Dismiss with the
   button or BTN1. Rank letter appears on the buy screen.
2. **Worse lap:** note the track `$/sec` and rank in the buy scene, race a
   deliberately slow lap → no modal, rank and `$/sec` in the buy scene are
   unchanged, and the ghost you race next lap is still the old (better) one.
3. **Better lap, same rank:** slightly beat your best without crossing a rank
   threshold → no modal, but track `$/sec` in the buy scene went up.
4. **Rank-up:** beat a rank threshold → modal `RANK <letter>!` with
   `Your Rate: $X -> $Y` (and `Ghost Rate` line only once that track has
   ghosts), values matching the buy screen after dismissal.
5. **A-rank unlock:** first time a track reaches A → the same modal also ends
   with "New track available in the shop!", and the `RANK A needed` row in
   the shop becomes a purchasable price. Only one modal appears.
6. **Quit mid-race:** QUIT button still returns to buy with nothing promoted.
7. **Persistence:** after a rank-up, restart the game → rank, ghost line, and
   `$/sec` survive; no modal re-appears.
