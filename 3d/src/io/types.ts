/**
 * The track-export schema: the one data boundary between the Lua exporter at the
 * repo root (T3) and every TypeScript consumer (T5 collision, T6 render, T9 lap,
 * T10 ghosts, T12 coins).
 *
 * Hand-written from `track_data.lua` *before* the exporter exists so both sides
 * can be built in parallel against one fixed shape. The exporter is expected to
 * be re-run as the 3D side discovers fields the first pass dropped — fixing the
 * shape first makes that a schema amendment rather than a renegotiation.
 *
 * ## Coordinate space
 *
 * One space, at two resolutions, with `tileSize` as the ratio between them:
 *
 * - **Grid units** (`col` / `row` / `w` / `h`) — the authored form, copied
 *   verbatim out of `track_data.lua`. Column runs +x (east), row runs +y
 *   (south). Origin is the top-left of the map.
 * - **Source pixels** (`LinePoint.x` / `.y`) — grid units times `tileSize`. The
 *   captured reference lap is recorded in this resolution and ships unchanged.
 *
 * Both are 2D and top-down, matching the Lua game. Lifting to three.js — which
 * axis becomes `z`, and at what scale — is `render/`'s business, not the
 * export's.
 *
 * **A position is the car's top-left corner, not its center.** `car.lua` tracks
 * the corner of a 16x16 box (`CAR_SIZE`), and `reference.lua` recorded the
 * reference lap straight off `car.x`/`car.y`, so `points[0]` of track3's lap is
 * exactly `spawn.col * tileSize, spawn.row * tileSize`. Anything that wants a
 * center adds `CAR_SIZE / 2` itself. Getting this wrong is a silent half-tile
 * offset, not a crash.
 */

/** Width of one tile in source pixels. `track_data.lua`'s `tile_size` (16). */
export type TileSize = number;

/**
 * Raw Tiled tile id, carried through unchanged rather than reduced to a
 * `solid: boolean`. Two distinct ids block (`WALL` and `SOLID`) and `road.lua`
 * paints them different colors; collapsing them here would throw away the only
 * information `render/track.ts` has to tell one barrier from another.
 *
 * Track 3 uses `WALL`, `ROAD` and `SOLID`; `ACCENT` is declared because
 * `road.is_drivable` accepts it, so a re-export of another track can't surprise
 * the collision test.
 */
export const Tile = {
  /** Off-track void. Blocks. Painted dark blue in 2D. */
  WALL: 0,
  /** Drivable road. */
  ROAD: 1,
  /** Blocking interior fill; also the tile `gates.lua` stamps. Painted black. */
  SOLID: 2,
  /** Drivable accent tile. Unused on track 3. */
  ACCENT: 3,
} as const;

export type TileId = (typeof Tile)[keyof typeof Tile];

/**
 * The drivable set, verbatim from `road.is_drivable` (`road.lua:85-87`):
 * `tile == 1 or tile == 3`. Everything else — including out-of-bounds, which
 * `road.get_tile` reports as `WALL` — blocks.
 */
export const DRIVABLE_TILES: ReadonlySet<number> = new Set([Tile.ROAD, Tile.ACCENT]);

/**
 * The tile layer, flat and row-major — the same layout `road.get_tile` indexes
 * (`layer[row * mw + col + 1]`), minus Lua's 1-based `+ 1`. Kept flat rather
 * than nested as rows precisely because the port of the collision index math is
 * then a transcription: `tiles[row * width + col]`.
 *
 * `tiles.length === width * height`.
 */
export interface TileMap {
  readonly width: number;
  readonly height: number;
  readonly tiles: readonly TileId[];
}

/** Authored spawn pose. */
export interface Spawn {
  readonly col: number;
  readonly row: number;
  /**
   * Facing in radians, 0 = +x (east), increasing clockwise in the top-down
   * space (because +y is south).
   *
   * Exported as data even though `car.reset` hardcodes `facing_angle = 0` for
   * every track. That hardcode is a *decision* about track 3 — it points the car
   * down the top straight — and it belongs in the track file, not buried in the
   * car port where T4 would have to re-derive it.
   */
  readonly facing: number;
}

/**
 * A checkpoint, as a grid-aligned rectangle in authored order: cross 1, then 2,
 * then 3, then rollover. Kept as `col`/`row`/`w`/`h` rather than pre-multiplied
 * pixels so the export stays a faithful mirror of `track_data.lua` and the one
 * multiplication lives in `trackData.ts` (`track_data.checkpoint_rect`).
 */
export interface Checkpoint {
  readonly col: number;
  readonly row: number;
  /** Width in tiles. */
  readonly w: number;
  /** Height in tiles. */
  readonly h: number;
}

/**
 * An authored coin slot: one tile, top-left at `col`/`row`
 * (`track_data.coin_rect`). These are fixed authored positions, not random
 * tiles — T12's top-up-to-N refills *these* slots.
 */
export interface CoinSlot {
  readonly col: number;
  readonly row: number;
}

/**
 * One sample of a racing line, in source pixels, top-left convention.
 *
 * **This is the single line format**, shared by the seeded reference lap and by
 * every line the player's own laps promote (T9/T10). That sharing is
 * load-bearing: `HEADING_DT` (`endless_dev.lua:56`) papers over lerp noise
 * between distance-downsampled points and is calibrated against *one*
 * resolution. Two resolutions in play means ghost facing angles jitter
 * differently depending on which source a ghost came from.
 *
 * The reference lap therefore ships already downsampled to the 6px `MIN_SPACING`
 * polyline `reference.lua:23` produces, and promotion must downsample to the
 * same spacing before installing a line.
 *
 * No `angle` field: the capture never recorded one. `ideal_line`
 * (`endless_dev.lua:237-245`) fills `angle = 0` and lets the `HEADING_DT`
 * lookahead derive travel direction off the polyline instead. The 3D side does
 * the same, in `sim/ghosts.ts` — one place, not two.
 */
export interface LinePoint {
  /** Seconds from lap start. Monotonic. */
  readonly t: number;
  readonly x: number;
  readonly y: number;
}

/**
 * The captured human lap, embedded rather than shipped alongside as a second
 * file. It is meaningless without this track's checkpoints and `tileSize`, one
 * exporter run produces both, and one fetch can't half-fail.
 *
 * Seeding from this is required, not optional: with telegraphing set to *none*,
 * a blind first lap means hunting invisible pickups on an unlearned track. Run
 * one must have a plausible ghost chain already in place.
 */
export interface ReferenceLap {
  readonly points: readonly LinePoint[];
}

/**
 * A whole exported track. Track 3 only — no `T` cycling, no other tracks.
 *
 * Bump `schemaVersion` on any breaking change; `trackData.ts` refuses to load a
 * version it doesn't know, so a stale `track3.json` fails loudly at boot rather
 * than one field at a time.
 */
export interface TrackExport {
  readonly schemaVersion: 1;
  /** `track_data.lua` key, e.g. `"track3"`. */
  readonly id: string;
  readonly tileSize: TileSize;
  readonly map: TileMap;
  readonly spawn: Spawn;
  readonly checkpoints: readonly Checkpoint[];
  /** The authored gold `coins` list. */
  readonly coins: readonly CoinSlot[];
  readonly referenceLap: ReferenceLap;
}

/**
 * Deliberately **not** exported, so a later re-export is a known amendment
 * rather than an oversight:
 *
 * - `coins2` — the lap-2 magenta field. The prototype runs one lap per rollover.
 * - `gates` — track 3 authors six, but `gates.enabled` requires `reverse_enabled`
 *   and the prototype has no flip/reverse move, so they'd be inert walls.
 * - `ranks` / `pay` / `unlock_cost` / `shop` / `base_coins` / `laps` — the rank
 *   ladder and economy are out of scope; T12's payouts are `TUNE` knobs (T8),
 *   not track data.
 * - The reference lap's `checkpoints: [{s, t}]` splits — an arc-length/pace ruler
 *   for the rank meter, which is out of scope. Recomputable from `points` plus
 *   `checkpoints` if a `$/sec` pace projection ever wants it.
 * - The `label` string and `REVERSE_MODE` mirroring.
 */
export type ExcludedFromExport = never;
