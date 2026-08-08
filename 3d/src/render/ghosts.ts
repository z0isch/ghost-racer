/**
 * The ghost field, drawn (T11, issue #12).
 *
 * Ports `draw_ghosts` and `draw_pace_ghost` (`endless_dev.lua:689-713`). Every
 * pose comes from `sim/ghosts.ts`; this file decides only what a pose *looks
 * like*, and reads sim state without ever writing it.
 *
 * ## Translucent parked karts
 *
 * The ghost fiction is kept: they are karts, stationary (`ghostSpeed` 0), laid
 * along your own promoted best lap, so retracing that lap precisely collects
 * everything. They are the same mesh the player drives — `kart.ts` owns it —
 * flattened to one tinted translucent colour, because the Lua tinted one sprite
 * and because a ghost is a *silhouette on a line*, not a second vehicle whose
 * paint job needs reading.
 *
 * **The accepted risk, restated so nobody solves it here** (plan, open risk 1):
 * kart-shaped pickups invite an instinctive swerve *away* from the thing the
 * player wants to hit. That is fog on the map. There is no proximity highlight,
 * no chevron, no audio cue, and no glow in this file — the cheapest lever if the
 * `$/sec` curve plateaus is a minimap, then turning `lineAlpha` up on the ribbon
 * `track.ts` already draws.
 *
 * ## Two alphas, because 3D took the sprite's edges away
 *
 * `ghostAlpha` is authored at **0.15** (`endless_dev.lua:107`), and it was a
 * usable number in 2D because a sprite at 15% still has hard pixel boundaries
 * against a flat field. A flat-shaded translucent box at 15% has no boundary at
 * all: it is a faint smear of road colour, and *which way it faces* — the only
 * thing a parked ghost has to communicate — goes with it.
 *
 * So each ghost is drawn twice from one geometry: a **fill** at `ghostAlpha`, and
 * its **edges** at `EDGE_ALPHA_GAIN x ghostAlpha`, clamped. The edges are what
 * the 2D sprite's outline was doing for free. One knob still drives both, so the
 * slider means what it has always meant and 0 is still invisible.
 *
 * Depth *testing* stays on, so a ghost behind a curb is occluded like anything
 * else; depth *writing* is off, so two overlapping ghosts don't punch each other
 * out. The consequence is that overlap reads denser rather than sorted, which at
 * this alpha is a fair trade — and along an arc-length-spaced field they rarely
 * overlap at all.
 *
 * ## The pace ghost
 *
 * `TUNE.paceGhost` is authored **on** and had no consumer at all before this
 * ticket: `sim/ghosts.ts` (T10) built the field, and the pace ghost is not in
 * the field. T8's rule for a knob nothing reads was to delete it (`hitstop`), so
 * the choice here was implement or drop — and it implements, because it is the
 * *in-world* form of the one comparison this whole prototype exists to make. It
 * is your best lap driving its own recorded pace against your current lap clock:
 * ahead of it or behind it, read without looking at a number.
 *
 * It is drawn car-sized rather than at `hitRadius`, in its own blue, and
 * `sim/ghosts.ts` never poses it into the field — it is a reference, not a
 * pickup, and nothing about it is collectable.
 */

import * as THREE from "three";
import { CAR_SIZE } from "../sim/car.js";
import { MAX_GHOSTS, TUNE } from "../sim/tune.js";
import type { GhostField } from "../sim/ghosts.js";
import { KART_VISUAL_SCALE, buildKartGeometry, kartScaleFor } from "./kart.js";
import { PALETTE } from "./track.js";

/**
 * How much firmer the edges are than the fill. The fill says *there is something
 * here*; the edges say *it is a kart, and it points that way*. Clamped at 1, so
 * turning `ghostAlpha` past 0.4 stops changing the outline and only thickens the
 * body — which is the direction a legibility nudge would want anyway.
 */
const EDGE_ALPHA_GAIN = 2.5;

export interface GhostView {
  /** Add this to the scene. Source pixels, same space as the track. */
  readonly object: THREE.Object3D;
  /**
   * The shared kart geometry, so the player kart can be built on this exact
   * instance. "The ghost mesh and the player mesh are the same mesh" is the
   * invariant this ticket exists to establish, and a second
   * `buildKartGeometry()` call anywhere would quietly break it. The field owns
   * it and disposes it; `createKart` never does.
   */
  readonly kartGeometry: THREE.BufferGeometry;
  /**
   * Redraw from the field's current poses. Called once per rendered frame, not
   * per fixed step: ghosts are static at the authored `ghostSpeed` of 0, so
   * there is nothing to interpolate and no `previous` pose to keep.
   */
  update(field: GhostField): void;
  dispose(): void;
}

/**
 * The field's view. Takes the shared kart geometry and **owns** it — the player
 * kart borrows the same instance, so disposal is one place (see `scene.ts`).
 */
export function createGhostView(): GhostView {
  const group = new THREE.Group();
  const geometry = buildKartGeometry();

  /**
   * Two materials for the whole field, not per ghost: every ghost is the same
   * tint at the same alpha, and the tint only changes when `boostOnHit` does.
   */
  const fillMat = new THREE.MeshLambertMaterial({
    color: PALETTE.ghostPickup,
    flatShading: true,
    transparent: true,
    opacity: TUNE.ghostAlpha,
    depthWrite: false,
  });
  const edgeMat = new THREE.LineBasicMaterial({
    color: PALETTE.ghostPickup,
    transparent: true,
    opacity: Math.min(1, TUNE.ghostAlpha * EDGE_ALPHA_GAIN),
    depthWrite: false,
  });
  const paceFillMat = new THREE.MeshLambertMaterial({
    color: PALETTE.ghostPace,
    flatShading: true,
    transparent: true,
    opacity: TUNE.ghostAlpha,
    depthWrite: false,
  });
  const paceEdgeMat = new THREE.LineBasicMaterial({
    color: PALETTE.ghostPace,
    transparent: true,
    opacity: Math.min(1, TUNE.ghostAlpha * EDGE_ALPHA_GAIN),
    depthWrite: false,
  });

  // Edges are derived once from the shared geometry. The 50-degree threshold is
  // measured, not guessed: it clears the octagonal wheels' 45-degree facet seams
  // (144 segments down to 112) while keeping every box corner and the wheel
  // discs' own rims. A wheel drawn as eight outlined quads is a scribble at this
  // size; its silhouette is the part that reads.
  const edgeGeometry = new THREE.EdgesGeometry(geometry, 50);

  /** One kart per slot, built up front and hidden rather than allocated in play. */
  const kart = (fill: THREE.Material, edge: THREE.Material): THREE.Object3D => {
    const holder = new THREE.Group();
    holder.add(
      new THREE.Mesh(geometry, fill),
      new THREE.LineSegments(edgeGeometry, edge),
    );
    holder.visible = false;
    group.add(holder);
    return holder;
  };

  // `MAX_GHOSTS` is the ceiling `TUNE.ghosts` is clamped to, so the pool can be
  // built once and never grow. Fifty hidden groups cost nothing; fifty
  // allocations during a tuning slider drag would.
  const pool = Array.from({ length: MAX_GHOSTS }, () => kart(fillMat, edgeMat));
  const pace = kart(paceFillMat, paceEdgeMat);
  // The pace kart is drawn at car size, not at the contact radius — it is not
  // collectable — so it takes the cosmetic shrink once, here, rather than per
  // frame like the pool above.
  pace.scale.setScalar(KART_VISUAL_SCALE);

  /** Last-pushed values, so the per-frame update touches materials only on change. */
  let shownAlpha = -1;
  let shownBoost: boolean | null = null;

  return {
    object: group,
    kartGeometry: geometry,

    update(field) {
      if (TUNE.ghostAlpha !== shownAlpha) {
        shownAlpha = TUNE.ghostAlpha;
        const edge = Math.min(1, shownAlpha * EDGE_ALPHA_GAIN);
        fillMat.opacity = shownAlpha;
        paceFillMat.opacity = shownAlpha;
        edgeMat.opacity = edge;
        paceEdgeMat.opacity = edge;
      }
      if (TUNE.boostOnHit !== shownBoost) {
        shownBoost = TUNE.boostOnHit;
        // Green is a pickup, pink is a hazard that ends the run. The tint *is*
        // the bet the knob is making, so it has to move with the knob.
        const tint = shownBoost ? PALETTE.ghostPickup : PALETTE.ghostHazard;
        fillMat.color.setHex(tint);
        edgeMat.color.setHex(tint);
      }

      // Sized to the contact radius, which is a live slider, then shrunk by the
      // same cosmetic factor the player kart wears so the field reads as the same
      // vehicle. Note the knock-on: the drawn ghost is now smaller than the
      // radius it is collected at, so "what you see is what you hit" holds only
      // for the centre — a ghost can be taken from a little outside its mesh.
      const scale = kartScaleFor(TUNE.hitRadius) * KART_VISUAL_SCALE;
      const count = field.count;

      for (let i = 0; i < pool.length; i++) {
        const holder = pool[i]!;
        // `pose` already returns null for a ghost taken this lap, which is what
        // drops it out of the draw for the rest of the lap
        // (`endless_dev.lua:692`). Nothing here tracks `taken` itself.
        const g = i < count ? field.pose(i) : null;
        if (g === null) {
          holder.visible = false;
          continue;
        }
        holder.visible = true;
        // Poses are top-left corners, like every position in this codebase; the
        // mesh is centred on its collision box.
        holder.position.set(g.x + CAR_SIZE / 2, 0, g.z + CAR_SIZE / 2);
        holder.rotation.y = -g.head;
        holder.scale.setScalar(scale);
      }

      const p = field.pacePose();
      pace.visible = p !== null;
      if (p !== null) {
        pace.position.set(p.x + CAR_SIZE / 2, 0, p.z + CAR_SIZE / 2);
        pace.rotation.y = -p.head;
      }
    },

    dispose() {
      group.clear();
      geometry.dispose();
      edgeGeometry.dispose();
      fillMat.dispose();
      edgeMat.dispose();
      paceFillMat.dispose();
      paceEdgeMat.dispose();
    },
  };
}
