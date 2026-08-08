import * as THREE from "three";
import { createKart, type Kart, type KartPose } from "./kart.js";
import { createGhostView, type GhostView } from "./ghosts.js";
import { createCoinView, type CoinView } from "./coins.js";
import { createTrack, PALETTE, type TrackView } from "./track.js";
import { createChaseCamera, type ChaseCamera } from "./camera.js";
import { type TrackExport } from "../io/types.js";
import type { GhostField } from "../sim/ghosts.js";
import type { CoinField } from "../sim/coins.js";

/**
 * The renderer, its lights, the track, and one kart. Owns the frame; the track's
 * own vocabulary — curb heights, palette, checkpoints — lives in `track.ts`, and
 * the camera's — the spring, the blend — in `camera.ts`.
 *
 * ## The camera is no longer here
 *
 * Through T4-T6 this file carried a deliberately dumb fixed-orientation overhead
 * follow cam: the same view the 2D game is judged in, so the car port's feel
 * judgements were about `car.lua`'s model and nothing else, and T7's decision
 * stayed uncontaminated by a chase cam improvised here.
 *
 * T7 has landed, so the scene now takes a `ChaseCamera` and does nothing to it
 * but hand it the aspect ratio. It is `loop.ts` — the composition root that owns
 * the sim/render split — that steps the camera, because the spring has to be
 * integrated on the *fixed* timestep, not per rendered frame (see `camera.ts`).
 *
 * The consequence that motivated the curbs is now visible: T6's barriers are
 * ankle-high for exactly this camera's sightlines.
 */
export interface Scene {
  /**
   * One frame: the kart at its interpolated pose, the ghost field at the poses
   * the sim currently reports, and the coin field at whichever slots are still
   * holding a coin.
   *
   * Both fields are passed in rather than held, because they are *sim* state and
   * this is the render side of the seam — the same reason `pose` is a parameter.
   * They are read every frame rather than pushed on change: at `ghostSpeed` 0
   * nothing moves, but `hitRadius`, `ghosts`, `taken` and every coin pickup
   * change without anybody notifying us, and a few dozen transforms a frame is
   * not worth a subscription.
   *
   * `wallSeconds` drives the coins' bob and spin, which are cosmetic and so run
   * on wall time rather than on the fixed step.
   */
  draw(pose: KartPose, ghosts: GhostField, coins: CoinField, wallSeconds: number): void;
  /** The rendered track, for callers that need its checkpoint / line knobs. */
  readonly track: TrackView;
  /** The chase camera. `loop.ts` steps it; nothing here does. */
  readonly camera: ChaseCamera;
  dispose(): void;
}

export function createScene(container: HTMLElement, track: TrackExport): Scene {
  const renderer = new THREE.WebGLRenderer({ antialias: true });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
  container.appendChild(renderer.domElement);

  const scene = new THREE.Scene();
  scene.background = new THREE.Color(PALETTE.sky);

  const chase = createChaseCamera();

  const trackView = createTrack(track);
  scene.add(trackView.object);

  // The field first: it builds the kart geometry both it and the player share,
  // and owns disposing it.
  const ghostView: GhostView = createGhostView();
  scene.add(ghostView.object);

  const coinView: CoinView = createCoinView(track);
  scene.add(coinView.object);

  const kart: Kart = createKart(ghostView.kartGeometry);
  scene.add(kart.object);

  // N64 lighting: one hard key for the flat-shaded facets to break against, and
  // a hemisphere fill so the shaded sides stay saturated instead of going grey.
  // No shadow maps — the art direction rules them out, and at curb height they
  // would contribute a millimetre of contact darkening and nothing else.
  const key = new THREE.DirectionalLight(0xffffff, 2.0);
  key.position.set(200, 400, 150);
  scene.add(key, new THREE.HemisphereLight(PALETTE.sky, 0x2a2352, 1.1));

  const resize = (): void => {
    const w = container.clientWidth || window.innerWidth;
    const h = container.clientHeight || window.innerHeight;
    // updateStyle left on: without the CSS size, the canvas lays out at its
    // *buffer* size, which devicePixelRatio has already multiplied — so on a 2x
    // display the canvas is twice the viewport and only its top-left quadrant is
    // visible, putting the centred kart down in the bottom-right corner.
    renderer.setSize(w, h);
    chase.setAspect(w / h);
  };
  resize();
  window.addEventListener("resize", resize);

  return {
    track: trackView,
    camera: chase,
    draw(pose, ghosts, coins, wallSeconds) {
      kart.update(pose);
      ghostView.update(ghosts);
      coinView.update(coins, wallSeconds);
      renderer.render(scene, chase.camera);
    },
    dispose() {
      window.removeEventListener("resize", resize);
      kart.dispose();
      ghostView.dispose();
      coinView.dispose();
      trackView.dispose();
      renderer.dispose();
      renderer.domElement.remove();
    },
  };
}
