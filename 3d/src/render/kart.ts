import * as THREE from "three";

/**
 * A placeholder kart: a flat-shaded box with a lighter nose block, sized to the
 * model's 16px collision square, plus a thin ground needle showing `velAngle`.
 *
 * Deliberately crude. T6 owns the render vocabulary and the N64 palette, and
 * kart geometry — procedural boxes vs. an authored low-poly asset — is still fog
 * on the map. What this has to do is exactly one thing: make facing and travel
 * direction separately legible, because a scalar-speed model's whole character
 * lives in the gap between them, and a symmetric blob hides it.
 */

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

/** Side of the collision box, in source pixels — `CAR_SIZE`. */
const SIZE = 16;

export interface Kart {
  readonly object: THREE.Object3D;
  update(pose: KartPose): void;
  dispose(): void;
}

export function createKart(): Kart {
  const group = new THREE.Group();

  const bodyGeom = new THREE.BoxGeometry(SIZE, SIZE * 0.55, SIZE * 0.8);
  const bodyMat = new THREE.MeshLambertMaterial({ color: 0xff5252, flatShading: true });
  const body = new THREE.Mesh(bodyGeom, bodyMat);
  body.position.y = SIZE * 0.3;
  group.add(body);

  // The nose sits at +x, which is facing 0 — the same convention as the sim.
  const noseGeom = new THREE.BoxGeometry(SIZE * 0.3, SIZE * 0.4, SIZE * 0.5);
  const noseMat = new THREE.MeshLambertMaterial({ color: 0xffe066, flatShading: true });
  const nose = new THREE.Mesh(noseGeom, noseMat);
  nose.position.set(SIZE * 0.5, SIZE * 0.45, 0);
  group.add(nose);

  // Travel direction, drawn on the ground and rotated independently of the body
  // so a drift shows as a visible wedge between kart and needle.
  const needleGeom = new THREE.BoxGeometry(SIZE * 1.6, 0.5, 1.5);
  const needleMat = new THREE.MeshBasicMaterial({ color: 0x4dd0e1 });
  const needle = new THREE.Mesh(needleGeom, needleMat);
  needle.position.set(SIZE * 0.8, 0.6, 0);
  const needlePivot = new THREE.Group();
  needlePivot.add(needle);
  group.add(needlePivot);

  return {
    object: group,
    update(pose) {
      // Sim tracks the box's top-left corner; the mesh is centered.
      group.position.set(pose.x + SIZE / 2, 0, pose.z + SIZE / 2);
      // three.js rotation.y turns +x toward -z, while the sim's angle turns +x
      // toward +z. Hence the negation, in one place, here.
      body.rotation.y = -pose.facingAngle;
      nose.position.set(
        Math.cos(pose.facingAngle) * SIZE * 0.5,
        SIZE * 0.45,
        Math.sin(pose.facingAngle) * SIZE * 0.5,
      );
      nose.rotation.y = -pose.facingAngle;
      needlePivot.rotation.y = -pose.velAngle;
      needleMat.color.setHex(pose.drifting ? 0xff9100 : 0x4dd0e1);
    },
    dispose() {
      bodyGeom.dispose();
      bodyMat.dispose();
      noseGeom.dispose();
      noseMat.dispose();
      needleGeom.dispose();
      needleMat.dispose();
    },
  };
}
