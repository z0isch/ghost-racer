import * as THREE from "three";

/**
 * The renderer, its camera, and one flat-shaded cube. N64-era palette: bright,
 * saturated, no PBR. Replaced piece by piece as `track.ts` / `kart.ts` land.
 *
 * Reads sim state, never writes it — `draw()` takes the interpolated angle as a
 * plain number.
 */
export interface Scene {
  draw(angle: number): void;
  dispose(): void;
}

export function createScene(container: HTMLElement): Scene {
  const renderer = new THREE.WebGLRenderer({ antialias: true });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
  container.appendChild(renderer.domElement);

  const scene = new THREE.Scene();
  scene.background = new THREE.Color(0x2b3a67);

  const camera = new THREE.PerspectiveCamera(60, 1, 0.1, 200);
  camera.position.set(3, 2.5, 4);
  camera.lookAt(0, 0, 0);

  const geometry = new THREE.BoxGeometry(1.4, 1.4, 1.4);
  const material = new THREE.MeshLambertMaterial({ color: 0xff5252, flatShading: true });
  const cube = new THREE.Mesh(geometry, material);
  scene.add(cube);

  const ground = new THREE.Mesh(
    new THREE.PlaneGeometry(40, 40),
    new THREE.MeshLambertMaterial({ color: 0x3ddc84, flatShading: true }),
  );
  ground.rotation.x = -Math.PI / 2;
  ground.position.y = -1.2;
  scene.add(ground);

  const key = new THREE.DirectionalLight(0xffffff, 2.2);
  key.position.set(4, 6, 3);
  scene.add(key, new THREE.AmbientLight(0xffd166, 0.9));

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
    draw(angle) {
      cube.rotation.y = angle;
      cube.rotation.x = angle * 0.35;
      renderer.render(scene, camera);
    },
    dispose() {
      window.removeEventListener("resize", resize);
      geometry.dispose();
      material.dispose();
      renderer.dispose();
      renderer.domElement.remove();
    },
  };
}
