import * as THREE from "three";
import { createKart, type Kart, type KartPose } from "./kart.js";
import { Tile, type TrackExport } from "../io/types.js";

/**
 * The renderer, its lights, the track's blocking tiles as boxes, and one kart.
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
 * ## The track here is a placeholder, not T6
 *
 * `buildTrack` below stamps one box per blocking tile through two
 * `InstancedMesh`es — flat colours, one height, no palette, no curbs, no
 * decoration. It exists because T5's question is *how does hitting a wall feel*,
 * and that cannot be judged against an invisible collision grid.
 *
 * **T6 owns `render/track.ts` and the real render vocabulary**, which is why the
 * placeholder deliberately squats in this file rather than claiming that
 * filename. What it does establish, and T6 inherits: `WALL` (0) and `SOLID` (2)
 * are painted *differently*, because on track 3 the outer boundary is `SOLID`
 * and the interior fill is `WALL` — the opposite of what the 2D palette's
 * ordering suggests (see T3's resolution).
 */
export interface Scene {
  draw(pose: KartPose): void;
  dispose(): void;
}

/** Camera height and southward pull-back, in source pixels. */
const CAM_HEIGHT = 260;
const CAM_BACK = 90;

/** Placeholder barrier height, source pixels. T6 decides the real one. */
const WALL_HEIGHT = 14;

export function createScene(container: HTMLElement, track: TrackExport): Scene {
  const TILE = track.tileSize;
  const worldW = track.map.width * TILE;
  const worldH = track.map.height * TILE;
  const renderer = new THREE.WebGLRenderer({ antialias: true });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
  container.appendChild(renderer.domElement);

  const scene = new THREE.Scene();
  scene.background = new THREE.Color(0x1b2340);

  const camera = new THREE.PerspectiveCamera(55, 1, 1, 4000);

  // The road surface. Sized to the world rather than to infinity so the edge of
  // the map is visible as an edge — off-map is not somewhere the car can be.
  const groundGeom = new THREE.PlaneGeometry(worldW, worldH);
  const groundMat = new THREE.MeshLambertMaterial({ color: 0x554b8c, flatShading: true });
  const ground = new THREE.Mesh(groundGeom, groundMat);
  ground.rotation.x = -Math.PI / 2;
  ground.position.set(worldW / 2, 0, worldH / 2);
  scene.add(ground);

  const grid = new THREE.GridHelper(Math.max(worldW, worldH), Math.max(worldW, worldH) / TILE);
  grid.position.set(worldW / 2, 0.05, worldH / 2);
  (grid.material as THREE.Material).opacity = 0.15;
  (grid.material as THREE.Material).transparent = true;
  scene.add(grid);

  const barriers = buildTrack(track, TILE);
  for (const b of barriers) scene.add(b);

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
      for (const b of barriers) {
        b.geometry.dispose();
        (b.material as THREE.Material).dispose();
      }
      groundGeom.dispose();
      groundMat.dispose();
      grid.dispose();
      renderer.dispose();
      renderer.domElement.remove();
    },
  };
}

/**
 * One box per blocking tile, batched into an `InstancedMesh` per tile id — 351
 * boxes on track 3, in two draw calls.
 *
 * Boxes sit on whole tile cells because that is precisely what
 * `sim/collision.ts` tests: the barrier you see is the barrier the four corner
 * samples hit, with no artistic slack between them. That exactness is the point
 * for T5 — a wall drawn even half a tile off would make a correct collision read
 * as a bug.
 */
function buildTrack(track: TrackExport, tileSize: number): THREE.InstancedMesh[] {
  const COLORS: ReadonlyMap<number, number> = new Map([
    [Tile.WALL, 0x2b2b57],
    [Tile.SOLID, 0x14141f],
  ]);

  const meshes: THREE.InstancedMesh[] = [];
  const matrix = new THREE.Matrix4();

  for (const [tileId, color] of COLORS) {
    const cells: number[] = [];
    for (let i = 0; i < track.map.tiles.length; i++) {
      if (track.map.tiles[i] === tileId) cells.push(i);
    }
    if (cells.length === 0) continue;

    const geom = new THREE.BoxGeometry(tileSize, WALL_HEIGHT, tileSize);
    const mat = new THREE.MeshLambertMaterial({ color, flatShading: true });
    const mesh = new THREE.InstancedMesh(geom, mat, cells.length);
    cells.forEach((cell, n) => {
      const col = cell % track.map.width;
      const row = Math.floor(cell / track.map.width);
      matrix.setPosition(
        col * tileSize + tileSize / 2,
        WALL_HEIGHT / 2,
        row * tileSize + tileSize / 2,
      );
      mesh.setMatrixAt(n, matrix);
    });
    mesh.instanceMatrix.needsUpdate = true;
    meshes.push(mesh);
  }

  return meshes;
}
