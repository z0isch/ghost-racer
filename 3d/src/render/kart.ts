/**
 * The kart — one mesh, drawn twice (T11, issue #12).
 *
 * This file owns **kart geometry**, which was fog on the map until T6 fixed the
 * render vocabulary. It lands here rather than in its own ticket because the
 * ghost mesh and the player mesh are the same mesh: two tickets would fight over
 * one asset. `render/ghosts.ts` calls `buildKartGeometry()` and swaps the
 * materials for a translucent tint; nothing else about the shape differs.
 *
 * ## Procedural boxes, not an authored asset
 *
 * The decision is **procedural**, built here in code:
 *
 * - There is no asset pipeline, and adding one buys nothing. A GLTF means a
 *   loader, a binary in git, a load-order await in the composition root, and a
 *   modelling tool in the loop for every proportion tweak. `pnpm dev` is the
 *   finish line (map, out of scope); an asset step is a second finish line.
 * - The art direction is already boxes. N64-era flat-shaded low-poly is what
 *   `track.ts` established, and a kart that is eight boxes and four eight-sided
 *   cylinders is *native* to that, not a compromise with it.
 * - Proportions are a feel judgement and this is a tuning prototype. The numbers
 *   below are editable in the same file as the thing that reads them, which is
 *   the same argument `sim/tune.ts` makes for every other feel number here.
 * - Fifty translucent ghosts have to be cheap. This is ~450 triangles, shared as
 *   one geometry across every kart in the scene.
 *
 * ## The silhouette has one job: say which way it points
 *
 * A parked ghost is a kart with no motion to read direction from, seen at 0.15
 * alpha from T7's low, close hood cam. So the shape is deliberately asymmetric
 * front-to-back along its whole height profile: a low pale nose wedge at the
 * front, mass and a tall rear wing at the back. The wheels give the axle line.
 * That is what makes "retracing my line collects everything" a thing you can
 * aim at rather than guess at.
 *
 * The player kart keeps T4's ground needle for `velAngle`. It is a debug cue,
 * not part of the kart, and the ghosts do not get one — a ghost has no velocity
 * and a needle on it would be the telegraphing the prototype withholds.
 */

import * as THREE from "three";
import { mergeGeometries } from "three/examples/jsm/utils/BufferGeometryUtils.js";
import { CAR_SIZE } from "../sim/car.js";
import { PALETTE } from "./track.js";

/**
 * What `render/` is allowed to know about the car: a pose, interpolated by the
 * loop. Reads sim state, never writes it.
 */
export interface KartPose {
  /** Source pixels, east. Top-left corner of the collision box. */
  x: number;
  /** Source pixels, south. */
  z: number;
  /** Radians, 0 = +x, increasing toward +z. */
  facingAngle: number;
  /** Radians. Diverges from `facingAngle` only in a drift. */
  velAngle: number;
  drifting: boolean;
}

/**
 * Material slots in the merged geometry, in group order. A caller passing an
 * array of three materials gets the parts coloured separately; a caller passing
 * one material — every ghost — gets the whole kart in that one colour, which is
 * what a tinted translucent silhouette wants.
 */
export const KART_SLOTS = { BODY: 0, ACCENT: 1, DARK: 2 } as const;

/**
 * Uniform scale that draws the kart at `size` source pixels long. The ghost
 * field uses it to draw at `TUNE.hitRadius`, mirroring `draw_ghosts`
 * (`endless_dev.lua:695-701`), which sizes the ghost sprite to the contact
 * radius rather than to the car: what you see is what you hit. Same lesson T5
 * learned about drawing barriers on whole tile cells.
 */
export function kartScaleFor(size: number): number {
  return size / CAR_SIZE;
}

export interface Kart {
  readonly object: THREE.Object3D;
  update(pose: KartPose): void;
  dispose(): void;
}

/**
 * The kart, centred on its collision box in x/z and standing on y = 0, facing
 * +x. One indexed geometry with three material groups.
 *
 * Every caller shares the result, so it is built once and disposed by whoever
 * built it — `scene.ts` composes the player and the field together, so in
 * practice the field owns it and hands it out.
 */
export function buildKartGeometry(): THREE.BufferGeometry {
  /** Forward is +x, up is +y, right is +z. Source pixels against `CAR_SIZE` 16. */
  const box = (w: number, h: number, d: number, x: number, y: number, z: number) => {
    const g = new THREE.BoxGeometry(w, h, d);
    g.translate(x, y, z);
    return g;
  };

  const WHEEL_R = 2.8;
  const wheel = (x: number, z: number) => {
    // Eight radial segments on purpose: a faceted wheel is the era, and at this
    // scale a smooth one is a grey dot.
    const g = new THREE.CylinderGeometry(WHEEL_R, WHEEL_R, 2.4, 8);
    // The cylinder's axis is y; the axle runs along z.
    g.rotateX(Math.PI / 2);
    g.translate(x, WHEEL_R, z);
    return g;
  };

  const slots = [
    // BODY — the chassis, and the only part in the bright hue.
    [box(13, 3, 7.5, -0.5, 4.4, 0)],
    // ACCENT — the nose wedge. Narrower and lower than the chassis, so the front
    // reads as pointed from above and as *low* from behind.
    [box(4.5, 2.4, 5.5, 7.5, 4.0, 0)],
    // DARK — wheels, cockpit, rear wing. The mass sits behind the axle midpoint
    // and the wing is the tallest thing on the kart: front-to-back asymmetry a
    // parked ghost can be read by.
    [
      wheel(5.0, -4.3),
      wheel(5.0, 4.3),
      wheel(-5.0, -4.3),
      wheel(-5.0, 4.3),
      box(5.5, 4.5, 6, -1.5, 8.0, 0),
      box(1.4, 4.0, 9.5, -6.8, 8.5, 0),
    ],
  ].map((parts) => {
    const merged = mergeGeometries(parts, false);
    for (const p of parts) p.dispose();
    if (merged === null) throw new Error("kart: slot merge failed");
    return merged;
  });

  const geom = mergeGeometries(slots, true);
  for (const s of slots) s.dispose();
  if (geom === null) throw new Error("kart: geometry merge failed");

  // Recentre on the collision box in x/z only — `center()` would sink the kart
  // by half its height. Doing it here means the part positions above can be
  // laid out by eye without anyone having to keep them balanced about the
  // origin, and `update()` can place the mesh from a top-left corner with one
  // half-tile offset and no per-part fudge.
  geom.computeBoundingBox();
  const bb = geom.boundingBox;
  if (bb !== null) geom.translate(-(bb.min.x + bb.max.x) / 2, 0, -(bb.min.z + bb.max.z) / 2);

  return geom;
}

/**
 * The player kart. Takes the shared geometry rather than building its own, so
 * the mesh the ghosts are drawn with is provably the mesh the player drives.
 */
export function createKart(geometry: THREE.BufferGeometry): Kart {
  const group = new THREE.Group();

  const materials = [
    new THREE.MeshLambertMaterial({ color: PALETTE.kart.body, flatShading: true }),
    new THREE.MeshLambertMaterial({ color: PALETTE.kart.accent, flatShading: true }),
    new THREE.MeshLambertMaterial({ color: PALETTE.kart.dark, flatShading: true }),
  ];
  const mesh = new THREE.Mesh(geometry, materials);
  group.add(mesh);

  // Travel direction, drawn on the ground and rotated independently of the body
  // so a drift shows as a visible wedge between kart and needle.
  const needleGeom = new THREE.BoxGeometry(CAR_SIZE * 1.6, 0.5, 1.5);
  const needleMat = new THREE.MeshBasicMaterial({ color: 0x4dd0e1 });
  const needle = new THREE.Mesh(needleGeom, needleMat);
  needle.position.set(CAR_SIZE * 0.8, 0.6, 0);
  const needlePivot = new THREE.Group();
  needlePivot.add(needle);
  group.add(needlePivot);

  return {
    object: group,
    update(pose) {
      // Sim tracks the box's top-left corner; the mesh is centred.
      group.position.set(pose.x + CAR_SIZE / 2, 0, pose.z + CAR_SIZE / 2);
      // three.js rotation.y turns +x toward -z, while the sim's angle turns +x
      // toward +z. Hence the negation, in one place, here.
      mesh.rotation.y = -pose.facingAngle;
      needlePivot.rotation.y = -pose.velAngle;
      needleMat.color.setHex(pose.drifting ? 0xff9100 : 0x4dd0e1);
    },
    dispose() {
      // Not the geometry: it is shared, and belongs to whoever built it.
      for (const m of materials) m.dispose();
      needleGeom.dispose();
      needleMat.dispose();
    },
  };
}
