import * as THREE from "three";
import { createKart, type Kart, type KartPose } from "./kart.js";

/**
 * The renderer, its lights, and an empty plane with one kart on it.
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
 * T4's feel judgement be about `car.lua`'s model and nothing else, and leaves
 * T7's decision uncontaminated by a chase cam improvised here.
 *
 * The ground is a bare grid at tile pitch. No walls, no track: an untextured
 * plane gives no sense of motion, and a grid is the cheapest thing that does.
 */
export interface Scene {
  draw(pose: KartPose): void;
  dispose(): void;
}

/** Source pixels per tile — `track_data.tile_size`. Grid pitch only. */
const TILE = 16;
/** Camera height and southward pull-back, in source pixels. */
const CAM_HEIGHT = 260;
const CAM_BACK = 90;

export function createScene(container: HTMLElement): Scene {
  const renderer = new THREE.WebGLRenderer({ antialias: true });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
  container.appendChild(renderer.domElement);

  const scene = new THREE.Scene();
  scene.background = new THREE.Color(0x1b2340);

  const camera = new THREE.PerspectiveCamera(55, 1, 1, 4000);

  const groundGeom = new THREE.PlaneGeometry(4000, 4000);
  const groundMat = new THREE.MeshLambertMaterial({ color: 0x2e7d5b, flatShading: true });
  const ground = new THREE.Mesh(groundGeom, groundMat);
  ground.rotation.x = -Math.PI / 2;
  scene.add(ground);

  const grid = new THREE.GridHelper(4000, 4000 / TILE, 0x53c48a, 0x3a8f6a);
  grid.position.y = 0.05;
  scene.add(grid);

  const kart: Kart = createKart();
  scene.add(kart.object);

  const key = new THREE.DirectionalLight(0xffffff, 2.2);
  key.position.set(200, 400, 150);
  scene.add(key, new THREE.AmbientLight(0xffd166, 0.8));

  const resize = (): void => {
    const w = container.clientWidth || window.innerWidth;
    const h = container.clientHeight || window.innerHeight;
    renderer.setSize(w, h, false);
    camera.aspect = w / h;
    camera.updateProjectionMatrix();
  };
  resize();
  window.addEventListener("resize", resize);

  return {
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
      groundGeom.dispose();
      groundMat.dispose();
      grid.dispose();
      renderer.dispose();
      renderer.domElement.remove();
    },
  };
}
