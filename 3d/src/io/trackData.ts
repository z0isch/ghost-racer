/**
 * Loading and validating the exported track JSON (T3, issue #4).
 *
 * The other half of the boundary `types.ts` describes: `export_track_3d.lua` at
 * the repo root writes `3d/data/track3.json`, and this reads it back.
 *
 * ## Why it validates rather than trusting the type
 *
 * The exporter is expected to be re-run as the 3D side discovers fields the
 * first pass dropped, so the two ends of this boundary drift out of step by
 * design. A plain `import ... as TrackExport` would let a stale export fail one
 * field at a time, deep inside collision or ghost layout, as an
 * `undefined is not a number` with no hint that the JSON is the problem.
 * `parseTrackExport` instead refuses at boot with the path of the field that
 * disagreed — `schemaVersion` first, so a genuinely old file says so in one
 * line.
 *
 * ## The one multiplication site
 *
 * Grid units become source pixels here and nowhere else (`checkpointRect` /
 * `coinRect`, mirroring `track_data.checkpoint_rect` / `coin_rect`). Every rect
 * this hands out is in the same top-left-corner space `types.ts` fixes, so a
 * consumer that wants a center adds `CAR_SIZE / 2` itself.
 */

import rawTrack3 from "../../data/track3.json";
import {
  Tile,
  type Checkpoint,
  type CoinSlot,
  type TileId,
  type TileSize,
  type TrackExport,
} from "./types.js";

/** The only `schemaVersion` this build understands. */
export const SCHEMA_VERSION = 1;

/** An axis-aligned rectangle in source pixels, top-left origin. */
export interface Rect {
  readonly x: number;
  readonly y: number;
  readonly w: number;
  readonly h: number;
}

// --- validation ------------------------------------------------------------

class TrackExportError extends Error {
  constructor(path: string, message: string) {
    super(`track export: ${path} ${message} — re-run \`lua export_track_3d.lua\` from the repo root`);
    this.name = "TrackExportError";
  }
}

function asObject(v: unknown, path: string): Record<string, unknown> {
  if (typeof v !== "object" || v === null || Array.isArray(v)) {
    throw new TrackExportError(path, `must be an object, got ${describe(v)}`);
  }
  return v as Record<string, unknown>;
}

function asArray(v: unknown, path: string): unknown[] {
  if (!Array.isArray(v)) {
    throw new TrackExportError(path, `must be an array, got ${describe(v)}`);
  }
  return v;
}

function asNumber(v: unknown, path: string): number {
  if (typeof v !== "number" || !Number.isFinite(v)) {
    throw new TrackExportError(path, `must be a finite number, got ${describe(v)}`);
  }
  return v;
}

/** A non-negative integer — every grid coordinate and dimension in the export. */
function asIndex(v: unknown, path: string): number {
  const n = asNumber(v, path);
  if (!Number.isInteger(n) || n < 0) {
    throw new TrackExportError(path, `must be a non-negative integer, got ${n}`);
  }
  return n;
}

function asString(v: unknown, path: string): string {
  if (typeof v !== "string") {
    throw new TrackExportError(path, `must be a string, got ${describe(v)}`);
  }
  return v;
}

function describe(v: unknown): string {
  if (v === null) return "null";
  if (Array.isArray(v)) return "an array";
  return typeof v;
}

const KNOWN_TILE_IDS: ReadonlySet<number> = new Set(Object.values(Tile));

function parseTileId(v: unknown, path: string): TileId {
  const n = asNumber(v, path);
  if (!KNOWN_TILE_IDS.has(n)) {
    throw new TrackExportError(path, `is tile id ${n}, which types.ts does not define`);
  }
  return n as TileId;
}

function parseCheckpoint(v: unknown, path: string): Checkpoint {
  const o = asObject(v, path);
  const w = asIndex(o["w"], `${path}.w`);
  const h = asIndex(o["h"], `${path}.h`);
  if (w === 0 || h === 0) {
    throw new TrackExportError(path, `is ${w}x${h} tiles; a checkpoint with no area can never be crossed`);
  }
  return { col: asIndex(o["col"], `${path}.col`), row: asIndex(o["row"], `${path}.row`), w, h };
}

function parseCoinSlot(v: unknown, path: string): CoinSlot {
  const o = asObject(v, path);
  return { col: asIndex(o["col"], `${path}.col`), row: asIndex(o["row"], `${path}.row`) };
}

/**
 * Validate a parsed JSON value as a `TrackExport`, or throw explaining which
 * field disagreed.
 *
 * Takes `unknown` rather than the import's inferred shape so the same function
 * guards a hand-edited file, a future `fetch`, or a fixture in a test.
 */
export function parseTrackExport(raw: unknown): TrackExport {
  const o = asObject(raw, "root");

  // First, and on its own: an old file should say "old file", not produce a
  // field-shaped complaint about whichever key happened to move.
  const schemaVersion = asNumber(o["schemaVersion"], "schemaVersion");
  if (schemaVersion !== SCHEMA_VERSION) {
    throw new TrackExportError(
      "schemaVersion",
      `is ${schemaVersion}, but this build only reads ${SCHEMA_VERSION}`,
    );
  }

  const id = asString(o["id"], "id");
  const tileSize = asIndex(o["tileSize"], "tileSize");
  if (tileSize === 0) throw new TrackExportError("tileSize", "must be non-zero");

  const mapObj = asObject(o["map"], "map");
  const width = asIndex(mapObj["width"], "map.width");
  const height = asIndex(mapObj["height"], "map.height");
  const rawTiles = asArray(mapObj["tiles"], "map.tiles");
  if (rawTiles.length !== width * height) {
    throw new TrackExportError(
      "map.tiles",
      `has ${rawTiles.length} entries, expected ${width * height} (${width}x${height})`,
    );
  }
  const tiles = rawTiles.map((t, i) => parseTileId(t, `map.tiles[${i}]`));

  const spawnObj = asObject(o["spawn"], "spawn");
  const spawn = {
    col: asIndex(spawnObj["col"], "spawn.col"),
    row: asIndex(spawnObj["row"], "spawn.row"),
    facing: asNumber(spawnObj["facing"], "spawn.facing"),
  };

  const checkpoints = asArray(o["checkpoints"], "checkpoints").map((cp, i) =>
    parseCheckpoint(cp, `checkpoints[${i}]`),
  );
  if (checkpoints.length === 0) {
    throw new TrackExportError("checkpoints", "is empty; a lap with no checkpoints never rolls over");
  }

  const coins = asArray(o["coins"], "coins").map((c, i) => parseCoinSlot(c, `coins[${i}]`));

  const lapObj = asObject(o["referenceLap"], "referenceLap");
  const rawPoints = asArray(lapObj["points"], "referenceLap.points");
  if (rawPoints.length === 0) {
    throw new TrackExportError("referenceLap.points", "is empty; run one is seeded from this lap");
  }
  const points = rawPoints.map((p, i) => {
    const path = `referenceLap.points[${i}]`;
    const po = asObject(p, path);
    return {
      t: asNumber(po["t"], `${path}.t`),
      x: asNumber(po["x"], `${path}.x`),
      y: asNumber(po["y"], `${path}.y`),
    };
  });

  // `t` is documented monotonic and the whole ghost-layout walk assumes it; an
  // out-of-order sample would show up much later as one ghost parked backwards.
  for (let i = 1; i < points.length; i++) {
    if (points[i]!.t < points[i - 1]!.t) {
      throw new TrackExportError(
        `referenceLap.points[${i}].t`,
        `is ${points[i]!.t}, before the previous sample's ${points[i - 1]!.t}; timestamps must be monotonic`,
      );
    }
  }

  // The capture was recorded straight off `car.x`/`car.y` from the spawn pose,
  // so the first sample is the spawn tile's top-left corner. The exporter checks
  // this too; checking again at boot is what catches a hand-edited file. Getting
  // it wrong is a silent offset in every seeded ghost, not a crash.
  const first = points[0]!;
  if (first.x !== spawn.col * tileSize || first.y !== spawn.row * tileSize) {
    throw new TrackExportError(
      "referenceLap.points[0]",
      `is (${first.x}, ${first.y}) but spawn is (${spawn.col * tileSize}, ${spawn.row * tileSize})`,
    );
  }

  return {
    schemaVersion: SCHEMA_VERSION,
    id,
    tileSize,
    map: { width, height, tiles },
    spawn,
    checkpoints,
    coins,
    referenceLap: { points },
  };
}

// --- grid to pixels --------------------------------------------------------

/** `track_data.checkpoint_rect`. */
export function checkpointRect(cp: Checkpoint, tileSize: TileSize): Rect {
  return { x: cp.col * tileSize, y: cp.row * tileSize, w: cp.w * tileSize, h: cp.h * tileSize };
}

/** `track_data.coin_rect` — one tile, top-left at the slot. */
export function coinRect(coin: CoinSlot, tileSize: TileSize): Rect {
  return { x: coin.col * tileSize, y: coin.row * tileSize, w: tileSize, h: tileSize };
}

/**
 * The playfield in source pixels. `car.lua` clamps position to
 * `usagi.GAME_W/GAME_H - CAR_SIZE`, and on track 3 that window is exactly the
 * tile grid (40x22 at 16px = 640x352) — so the clamp T5 ports reads its bounds
 * from here rather than from a second hardcoded 640.
 */
export function worldSize(track: TrackExport): { readonly w: number; readonly h: number } {
  return { w: track.map.width * track.tileSize, h: track.map.height * track.tileSize };
}

// --- the track itself ------------------------------------------------------

/**
 * Track 3, validated at module load. Bundled as a static import rather than
 * fetched: it is the only track, it is needed before the first frame, and a
 * synchronous boot keeps `loop.ts` free of a loading state.
 */
export const track3: TrackExport = parseTrackExport(rawTrack3);
