/**
 * Track 3, rendered (T6, issue #7).
 *
 * Replaces the placeholder `buildTrack` that squatted in `scene.ts` for T5 and
 * establishes the render vocabulary the rest of `render/` inherits.
 *
 * ## The three rules this file is built around
 *
 * **Curb height.** Barriers are ankle-high — `CURB_HEIGHT` is 6 source pixels
 * against the kart's 16px box. They are walls you clip, not walls you look at,
 * so the sightline down a straight is unbroken and the whole track shape is
 * readable from a chase cam. The consequence is deliberate: you can see over
 * the outer boundary into the void, because off-map is not somewhere the car
 * can be and pretending otherwise costs the sightline.
 *
 * **Whole tile cells.** Every box is exactly one tile, centred on that tile,
 * because that is precisely what `sim/collision.ts` tests — the barrier you see
 * is the barrier the four corner samples hit, with no artistic slack between
 * them. T5's resolution is explicit about this: a wall drawn even half a tile
 * off makes correct collision read as a bug. Nothing here is inset, bevelled or
 * nudged for looks.
 *
 * **No telegraphing.** Checkpoints are drawn because they are the lap's
 * structure, and nothing else is. No minimap, no chevrons, no arrows, no
 * proximity glow, no rendered racing line (`lineAlpha` defaults to 0 — see
 * `setLineAlpha`). The prototype's whole legibility question is whether pure
 * memory is enough, and answering it requires actually withholding the aids.
 *
 * ## Palette
 *
 * N64-era: flat-shaded, bright, saturated, no PBR, no shadows. It re-hues
 * `road.lua`'s violet theme upward rather than replacing it — the 2D game's
 * *structure* is what the eye reads at speed, so what carries over is the
 * relationships, not the hex values: road brighter than its barriers, the
 * checkpoint outline a step darker than its fill.
 *
 * The one thing that does not carry over is which tile id is the outside.
 * `road.lua` paints `WALL` (0) dark blue and `SOLID` (2) black, which reads as
 * "0 is the surround" — on track 3 it is the reverse. The outer boundary is
 * `SOLID` and the interior islands are `WALL` (see T3's resolution), so the
 * dark near-black goes on `SOLID` here.
 */

import * as THREE from "three";
import { DRIVABLE_TILES, Tile, type LinePoint, type TileId, type TrackExport } from "../io/types.js";
import { checkpointRect, worldSize } from "../io/trackData.js";
import type { CheckpointState } from "../sim/lap.js";

/** Barrier height in source pixels. Ankle-high against `CAR_SIZE` (16). */
const CURB_HEIGHT = 6;

/** Height of the lighter band capping each barrier. Part of `CURB_HEIGHT`. */
const CURB_CAP_HEIGHT = 1.5;

/**
 * The N64 palette. Exported because `scene.ts` needs the sky to match and
 * `ghosts.ts` (T11) will want to sit its translucent karts against the road
 * colour rather than pick a new one.
 */
export const PALETTE = {
  /** Clear colour. Bright enough that the curb silhouette reads against it. */
  sky: 0x4fc3f7,
  /** Tile fills, keyed by tile id. */
  tiles: {
    [Tile.WALL]: 0x3f51d5,
    [Tile.ROAD]: 0x7a67d9,
    [Tile.SOLID]: 0x1b1f36,
    [Tile.ACCENT]: 0xf2efff,
  } as Record<TileId, number>,
  /** Top band of a barrier: the same hue, lifted, so the edge reads at speed. */
  caps: {
    [Tile.WALL]: 0x7d8bff,
    [Tile.ROAD]: 0x7a67d9,
    [Tile.SOLID]: 0x424a73,
    [Tile.ACCENT]: 0xffffff,
  } as Record<TileId, number>,
  /** `road.lua`'s `cp_fill` / `cp_line`, brightened. Outline a step darker. */
  checkpointFill: 0x35d07f,
  checkpointLine: 0x1a6b46,
  /** The racing line, when `lineAlpha` is turned up. */
  line: 0xffe066,
  /**
   * The kart, player and ghost alike (T11). One mesh, three material slots —
   * see `kart.ts`. Warm yellow against the violet road is the widest hue gap
   * the theme has, which is what a chase cam needs from the thing it follows;
   * `dark` is the same near-black the outside boundary uses, so wheels and
   * cockpit read as silhouette rather than as another colour to track.
   */
  kart: {
    body: 0xffe066,
    accent: 0xf2efff,
    dark: 0x1b1f36,
  },
  /**
   * Ghost tints, `endless_dev.lua:668-671`. The field's tint is the *bet*: green
   * while `boostOnHit` is on (a pickup), pink when it is off (a hazard that ends
   * the run). Deliberately not reusing `checkpointFill` for the green — a tweak
   * to a checkpoint pad should not move what the ghosts look like.
   */
  ghostPickup: 0x4dffa0,
  ghostHazard: 0xff5cc8,
  /** The non-interactive pace ghost, `PACE_GHOST_TINT`. */
  ghostPace: 0x5cc8ff,
  /**
   * The coin field (T12). Gold, and deliberately a *deeper* one than the kart's
   * warm yellow: the coins are the competing route the plan names (open risk 2),
   * so telling a coin from your own kart at the edge of vision has to be free.
   * `coinRim` lights the disc's rim so it still reads at the moment its spin
   * turns it edge-on.
   */
  coin: 0xffc61a,
  coinRim: 0xfff0a8,
} as const;

/** Blocking tiles, derived from the drivable set so the two can't disagree. */
const BLOCKING_TILES: readonly TileId[] = (Object.values(Tile) as TileId[]).filter(
  (t) => !DRIVABLE_TILES.has(t),
);

/**
 * Half-width of the racing-line ribbon in source pixels. A `THREE.Line` would
 * be simpler, but WebGL caps line width at 1px on every platform that matters,
 * which at this world scale is invisible.
 */
const LINE_HALF_WIDTH = 1.5;

/** Ground clearances, small and ordered so nothing z-fights. */
const Y_CHECKPOINT_OUTLINE = 0.1;
const Y_CHECKPOINT_FILL = 0.2;
const Y_LINE = 0.3;

export interface TrackView {
  /** Add this to the scene. Positioned in source pixels, world origin at the map's top-left. */
  readonly object: THREE.Object3D;
  /**
   * Repaint the pads, one state per checkpoint in authored order. T9 owns lap
   * state and drives this; until then every checkpoint renders live.
   */
  setCheckpointStates(states: readonly CheckpointState[]): void;
  /**
   * The racing line, off by default (`endless_dev.lua:107`, `line_alpha = 0`).
   *
   * The knob is kept because it is the map's first legibility fallback if the
   * `$/sec` curve plateaus — but it is *off*, because a rendered line is the
   * telegraphing the whole prototype is built to do without.
   */
  setLineAlpha(alpha: number): void;
  /**
   * Repoint the ribbon at a different polyline — the promoted line (T10), which
   * replaces the seeded reference lap this view is built with the moment a lap
   * wins on `$/sec`. Drawing the reference lap after that would be showing the
   * player a route the ghosts are no longer standing on.
   *
   * Rebuilds the geometry, so call it when the line *changes* (once per
   * rollover) rather than per frame. `endless_dev.lua:676` is explicit that the
   * whole loop is drawn at constant alpha and frozen until rollover: on a closed
   * loop "the path they will take" is the entire loop, and it cannot morph
   * mid-lap without becoming unreadable.
   */
  setLine(points: readonly LinePoint[]): void;
  dispose(): void;
}

export interface TrackViewOptions {
  /** Initial racing-line opacity. Defaults to 0 — see `setLineAlpha`. */
  readonly lineAlpha?: number;
}

export function createTrack(track: TrackExport, options: TrackViewOptions = {}): TrackView {
  const tile = track.tileSize;
  const world = worldSize(track);
  const group = new THREE.Group();

  /** Everything this view owns, disposed in one pass rather than by hand. */
  const owned: { dispose(): void }[] = [];
  const own = <T extends { dispose(): void }>(thing: T): T => {
    owned.push(thing);
    return thing;
  };

  // --- the road ------------------------------------------------------------
  //
  // One plane in the road colour, sized to the map rather than to infinity so
  // the edge of the world is visible as an edge. Blocking tiles cover their own
  // cells completely, so the plane never shows through where it shouldn't.
  const groundGeom = own(new THREE.PlaneGeometry(world.w, world.h));
  const groundMat = own(new THREE.MeshLambertMaterial({ color: PALETTE.tiles[Tile.ROAD] }));
  const ground = new THREE.Mesh(groundGeom, groundMat);
  ground.rotation.x = -Math.PI / 2;
  ground.position.set(world.w / 2, 0, world.h / 2);
  group.add(ground);

  // Accent tiles are drivable, so they are paint on the road rather than a box.
  // Track 3 authors none; this exists so a re-export of another track doesn't
  // silently render its accents as road.
  const accentCells = cellsOf(track, Tile.ACCENT);
  if (accentCells.length > 0) {
    const geom = own(new THREE.PlaneGeometry(tile, tile));
    const mat = own(new THREE.MeshLambertMaterial({ color: PALETTE.tiles[Tile.ACCENT] }));
    const mesh = own(new THREE.InstancedMesh(geom, mat, accentCells.length));
    const m = new THREE.Matrix4();
    const flat = new THREE.Quaternion().setFromEuler(new THREE.Euler(-Math.PI / 2, 0, 0));
    const one = new THREE.Vector3(1, 1, 1);
    accentCells.forEach((cell, n) => {
      const { x, z } = cellCenter(track, cell);
      m.compose(new THREE.Vector3(x, 0.05, z), flat, one);
      mesh.setMatrixAt(n, m);
    });
    mesh.instanceMatrix.needsUpdate = true;
    group.add(mesh);
  }

  // --- barriers ------------------------------------------------------------
  //
  // One box per blocking tile, batched per tile id, plus a lighter cap band on
  // top of each. Track 3 is 351 blocking tiles in four draw calls.
  for (const tileId of BLOCKING_TILES) {
    const cells = cellsOf(track, tileId);
    if (cells.length === 0) continue;

    const body = own(
      new THREE.InstancedMesh(
        own(new THREE.BoxGeometry(tile, CURB_HEIGHT - CURB_CAP_HEIGHT, tile)),
        own(
          new THREE.MeshLambertMaterial({ color: PALETTE.tiles[tileId], flatShading: true }),
        ),
        cells.length,
      ),
    );
    const cap = own(
      new THREE.InstancedMesh(
        own(new THREE.BoxGeometry(tile, CURB_CAP_HEIGHT, tile)),
        own(new THREE.MeshLambertMaterial({ color: PALETTE.caps[tileId], flatShading: true })),
        cells.length,
      ),
    );

    const m = new THREE.Matrix4();
    cells.forEach((cell, n) => {
      const { x, z } = cellCenter(track, cell);
      m.setPosition(x, (CURB_HEIGHT - CURB_CAP_HEIGHT) / 2, z);
      body.setMatrixAt(n, m);
      m.setPosition(x, CURB_HEIGHT - CURB_CAP_HEIGHT / 2, z);
      cap.setMatrixAt(n, m);
    });
    body.instanceMatrix.needsUpdate = true;
    cap.instanceMatrix.needsUpdate = true;
    group.add(body, cap);
  }

  // --- checkpoints ---------------------------------------------------------
  //
  // A floor pad per checkpoint: an outline plate with an inset fill sitting on
  // it, which is `road.draw_checkpoint` in three dimensions. Flat on the ground
  // rather than raised into a gate, because a gate you can see over the curbs
  // *is* a chevron — it would telegraph the route from across the map.
  //
  // No number labels. The 2D draw only writes them when there is more than one
  // checkpoint, and it can afford a bitmap font over a top-down view; here they
  // would need a texture atlas to say something the crossed/live fade already
  // says at the only moment it matters.
  const outlineMat = own(
    new THREE.MeshBasicMaterial({ color: PALETTE.checkpointLine, side: THREE.DoubleSide }),
  );
  const outlineCrossedMat = own(
    new THREE.MeshBasicMaterial({ color: PALETTE.checkpointFill, side: THREE.DoubleSide }),
  );
  const fillMat = own(
    new THREE.MeshBasicMaterial({ color: PALETTE.checkpointFill, side: THREE.DoubleSide }),
  );
  /** Outline border thickness, source pixels. */
  const CP_BORDER = 2;

  const checkpoints = track.checkpoints.map((cp) => {
    const rect = checkpointRect(cp, tile);

    const outlineGeom = own(new THREE.PlaneGeometry(rect.w, rect.h));
    const outline = new THREE.Mesh(outlineGeom, outlineMat);
    outline.rotation.x = -Math.PI / 2;
    outline.position.set(rect.x + rect.w / 2, Y_CHECKPOINT_OUTLINE, rect.y + rect.h / 2);

    const fillGeom = own(
      new THREE.PlaneGeometry(
        Math.max(rect.w - CP_BORDER * 2, 1),
        Math.max(rect.h - CP_BORDER * 2, 1),
      ),
    );
    const fill = new THREE.Mesh(fillGeom, fillMat);
    fill.rotation.x = -Math.PI / 2;
    fill.position.set(rect.x + rect.w / 2, Y_CHECKPOINT_FILL, rect.y + rect.h / 2);

    group.add(outline, fill);
    return { outline, fill };
  });

  // --- the racing line -----------------------------------------------------

  // Seeded with the reference lap, repointed at the promoted line by `setLine`.
  // Owned by hand rather than through `own`, since it is the one thing here that
  // is replaced during the session: the old geometry is disposed as it goes.
  let lineGeom = ribbon(track.referenceLap.points, LINE_HALF_WIDTH, Y_LINE);
  const lineMat = own(
    new THREE.MeshBasicMaterial({
      color: PALETTE.line,
      transparent: true,
      opacity: 0,
      side: THREE.DoubleSide,
      depthWrite: false,
    }),
  );
  const line = new THREE.Mesh(lineGeom, lineMat);
  line.visible = false;
  /** Whether the current polyline has anything to draw at all. */
  let lineVisible = track.referenceLap.points.length >= 2;
  group.add(line);

  const view: TrackView = {
    object: group,
    setCheckpointStates(states) {
      checkpoints.forEach((cp, i) => {
        // An unknown index is treated as the target rather than hidden: a short
        // array should leave the lap's structure visible, not erase it.
        const state = states[i] ?? "target";
        const gone = state === "crossed";
        cp.outline.visible = !gone;
        cp.fill.visible = !gone && state === "target";
        cp.outline.material = state === "pending" ? outlineCrossedMat : outlineMat;
      });
    },
    setLineAlpha(alpha) {
      lineMat.opacity = alpha;
      line.visible = alpha > 0 && lineVisible;
    },
    setLine(points) {
      const next = ribbon(points, LINE_HALF_WIDTH, Y_LINE);
      lineGeom.dispose();
      lineGeom = next;
      line.geometry = next;
      // A polyline too short to have segments produces an empty geometry, which
      // renders as nothing but would leave the alpha knob claiming a line is up.
      lineVisible = points.length >= 2;
      view.setLineAlpha(lineMat.opacity);
    },
    dispose() {
      group.clear();
      lineGeom.dispose();
      for (const thing of owned) thing.dispose();
    },
  };

  view.setLineAlpha(options.lineAlpha ?? 0);
  return view;
}

/** Flat indices of every cell holding `tileId`, in row-major order. */
function cellsOf(track: TrackExport, tileId: TileId): number[] {
  const cells: number[] = [];
  for (let i = 0; i < track.map.tiles.length; i++) {
    if (track.map.tiles[i] === tileId) cells.push(i);
  }
  return cells;
}

/**
 * The centre of a cell in source pixels. The export's positions are top-left
 * corners; three.js meshes are centred, so the half-tile is added here and
 * nowhere else in this file.
 */
function cellCenter(track: TrackExport, cell: number): { x: number; z: number } {
  const col = cell % track.map.width;
  const row = Math.floor(cell / track.map.width);
  return {
    x: col * track.tileSize + track.tileSize / 2,
    z: row * track.tileSize + track.tileSize / 2,
  };
}

/**
 * A flat ribbon along a polyline, `halfWidth` to each side, laid at height `y`.
 *
 * The offset at each sample uses the direction to its neighbour rather than a
 * mitre: the reference lap is downsampled to 6px spacing, so a mitre at a
 * hairpin would swing wider than the ribbon is worth. `LinePoint.y` is south,
 * which is `z` here.
 */
function ribbon(points: readonly LinePoint[], halfWidth: number, y: number): THREE.BufferGeometry {
  const geom = new THREE.BufferGeometry();
  if (points.length < 2) return geom;

  const positions = new Float32Array(points.length * 6);
  for (let i = 0; i < points.length; i++) {
    const prev = points[Math.max(i - 1, 0)]!;
    const next = points[Math.min(i + 1, points.length - 1)]!;
    let dx = next.x - prev.x;
    let dz = next.y - prev.y;
    const len = Math.hypot(dx, dz) || 1;
    dx /= len;
    dz /= len;
    // Perpendicular in the ground plane.
    const nx = -dz * halfWidth;
    const nz = dx * halfWidth;
    const p = points[i]!;
    positions.set([p.x + nx, y, p.y + nz, p.x - nx, y, p.y - nz], i * 6);
  }

  const indices: number[] = [];
  for (let i = 0; i < points.length - 1; i++) {
    const a = i * 2;
    indices.push(a, a + 1, a + 2, a + 1, a + 3, a + 2);
  }

  geom.setAttribute("position", new THREE.BufferAttribute(positions, 3));
  geom.setIndex(indices);
  return geom;
}
