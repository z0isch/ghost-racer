import * as THREE from "three";
import { createKart, type Kart, type KartPose } from "./kart.js";
import { createTrack, PALETTE, type TrackView } from "./track.js";
import { type TrackExport } from "../io/types.js";

/**
 * The renderer, its lights, the track, and one kart. Owns the frame; the track's
 * own vocabulary — curb heights, palette, checkpoints — lives in `track.ts`.
 *
 * ## Why the camera here is deliberately dumb
 *
 * The map's camera decision — a damped spring blend toward `vel_angle` — is T7's
 * whole ticket, and it is the decision most likely to be blamed for the model
 * feeling wrong ("the physics broke in 3D" when nothing broke but the view). So
 * this scene ships the opposite: a **fixed-orientation overhead follow cam**
 * that only ever translates. North stays up, nothing swings, nothing damps.
 *
 * That is the same view the 2D game is judged in, which is the point — it lets
 * T4's and T5's feel judgements be about `car.lua`'s model and nothing else, and
 * leaves T7's decision uncontaminated by a chase cam improvised here.
 *
 * One consequence worth naming: T6's curbs are ankle-high for a *chase* cam's
 * sightlines, and from directly overhead they are almost edge-on. The track will
 * look flatter here than it is meant to until T7 lands.
 */
export interface Scene {
  draw(pose: KartPose): void;
  /** The rendered track, for callers that need its checkpoint / line knobs. */
  readonly track: TrackView;
  dispose(): void;
}

/** Camera height and southward pull-back, in source pixels. */
const CAM_HEIGHT = 260;
const CAM_BACK = 90;

export function createScene(container: HTMLElement, track: TrackExport): Scene {
  const TILE = track.tileSize;
  const renderer = new THREE.WebGLRenderer({ antialias: true });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
  container.appendChild(renderer.domElement);

  const scene = new THREE.Scene();
  scene.background = new THREE.Color(PALETTE.sky);

  const camera = new THREE.PerspectiveCamera(55, 1, 1, 4000);

  const trackView = createTrack(track);
  scene.add(trackView.object);

  const kart: Kart = createKart();
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
    camera.aspect = w / h;
    camera.updateProjectionMatrix();
  };
  resize();
  window.addEventListener("resize", resize);

  return {
    track: trackView,
    draw(pose) {
      kart.update(pose);
      const cx = pose.x + TILE / 2;
      const cz = pose.z + TILE / 2;
      // Pulled back along +z (south) rather than sitting straight overhead: a
      // camera directly above has its look direction parallel to `up`, and the
      // tilt also keeps the kart's facing readable in silhouette.
      camera.position.set(cx, CAM_HEIGHT, cz + CAM_BACK);
      camera.lookAt(cx, 0, cz);
      renderer.render(scene, camera);
    },
    dispose() {
      window.removeEventListener("resize", resize);
      kart.dispose();
      trackView.dispose();
      renderer.dispose();
      renderer.domElement.remove();
    },
  };
}
