/**
 * The coin field, drawn (T12, issue #13).
 *
 * Ports `draw_coins` (`endless_dev.lua:715-721`): one coin per present slot,
 * bobbing on a shared sine. `sim/coins.ts` owns which slots are present; this
 * file decides only what one looks like, and reads sim state without writing it.
 *
 * ## A standing disc, not a flat sprite
 *
 * The 2D game drew a 16px sprite lying in the tile, which from directly overhead
 * is a coin. From T7's low, close chase camera a disc lying on the ground is a
 * smear a car length ahead and invisible beyond that. So the coin stands on its
 * edge and spins about the vertical, which is the arcade convention for exactly
 * this reason: it presents a face from every approach angle, and the spin is
 * what makes it read as a pickup rather than as track decoration.
 *
 * It hovers clear of `CURB_HEIGHT`, so a coin behind a barrier is visible over
 * it. That is not telegraphing in the sense the plan rules out — the coins are
 * authored, static and never on the ghost chain; what stays unlit is *where the
 * chain goes*.
 *
 * The bob keeps `endless_dev.lua`'s own constants rather than being re-tuned for
 * 3D. It is 0.6 source pixels, which is nearly nothing here, and that is fine:
 * in 2D the bob was the only motion a coin had, and in 3D the spin does that
 * work. Leaving the number alone keeps one fewer invented constant on the map.
 */

import * as THREE from "three";
import type { CoinField } from "../sim/coins.js";
import { coinRect } from "../io/trackData.js";
import type { TrackExport } from "../io/types.js";
import { PALETTE } from "./track.js";

/** `endless_dev.lua:71-72` — the sprite bob, in source pixels and Hz. */
const COIN_BOB_AMP = 0.6;
const COIN_BOB_HZ = 1.5;

/** Turns per second about the vertical. The 3D stand-in for the 2D bob. */
const COIN_SPIN_HZ = 0.6;

/** Disc size and hover height, as fractions of a tile. */
const COIN_RADIUS = 0.3;
const COIN_THICKNESS = 0.09;
const COIN_HEIGHT = 0.55;

/** Facets around the disc. Enough to read round, few enough to read N64. */
const COIN_SEGMENTS = 12;

export interface CoinView {
  /** Add this to the scene. Source pixels, same space as the track. */
  readonly object: THREE.Object3D;
  /**
   * Redraw from the field's current state. Called once per rendered frame with
   * the loop's wall-clock seconds: the bob and the spin are cosmetic, so they
   * run on wall time rather than on the fixed step, exactly like the HUD's
   * flash fade.
   */
  update(field: CoinField, wallSeconds: number): void;
  dispose(): void;
}

/**
 * The field's view. Built from the *track's* authored slots rather than from a
 * `CoinField`, so the scene can stand up before the sim does — the field itself
 * is passed to `update` every frame, on the same terms as the ghosts: it is sim
 * state, and this is the render side of the seam.
 */
export function createCoinView(track: TrackExport): CoinView {
  const group = new THREE.Group();
  const tile = track.tileSize;

  // Standing on edge: the cylinder's axis is Y by default, so the geometry is
  // tipped once at build time and every instance then spins about the world
  // vertical rather than about its own tipped axis.
  const geometry = new THREE.CylinderGeometry(
    tile * COIN_RADIUS,
    tile * COIN_RADIUS,
    tile * COIN_THICKNESS,
    COIN_SEGMENTS,
  );
  geometry.rotateX(Math.PI / 2);

  const material = new THREE.MeshLambertMaterial({
    color: PALETTE.coin,
    emissive: PALETTE.coinRim,
    // Coins sit in the shadowed half of the key light as often as not, and a
    // pickup that dims when you approach from the wrong side is a pickup you
    // stop seeing. A little self-lighting keeps the gold constant.
    emissiveIntensity: 0.35,
    flatShading: true,
  });

  /**
   * One mesh per authored slot, built up front and hidden rather than allocated
   * as coins come and go. The slot list is fixed for the session, so the pool
   * never grows.
   */
  const pool = track.coins.map((slot) => {
    const rect = coinRect(slot, tile);
    const mesh = new THREE.Mesh(geometry, material);
    // Slots are tile rects in the same top-left space as everything else.
    mesh.position.set(rect.x + rect.w / 2, tile * COIN_HEIGHT, rect.y + rect.h / 2);
    group.add(mesh);
    return mesh;
  });

  return {
    object: group,

    update(f, wallSeconds) {
      // One phase for the whole field, like the Lua's single `bob`: coins in
      // sync read as a set, coins out of phase read as clutter.
      const bob = Math.sin(wallSeconds * COIN_BOB_HZ * 2 * Math.PI) * COIN_BOB_AMP;
      const spin = wallSeconds * COIN_SPIN_HZ * 2 * Math.PI;
      for (let i = 0; i < pool.length; i++) {
        const mesh = pool[i]!;
        mesh.visible = f.present(i);
        if (!mesh.visible) continue;
        mesh.position.y = tile * COIN_HEIGHT + bob;
        mesh.rotation.y = spin;
      }
    },

    dispose() {
      group.clear();
      geometry.dispose();
      material.dispose();
    },
  };
}
