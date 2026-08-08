/**
 * Cash popups: the `+$N` that rises off whatever just paid.
 *
 * Ports `popups.lua`'s cash pops — `M.spawn` (:19) and the cash half of
 * `M.draw` (:76-92) — with the Lua's own constants: 1.5s of life, a 50px rise,
 * a per-pop wiggle seeded on spawn position so a burst of pops does not wobble
 * in unison, and the ghost variant drawn smaller and dimmer than a coin or a
 * checkpoint.
 *
 * ## Why the pop is in the world, not on the HUD
 *
 * The 2D game drew these in screen space, but it was drawing a camera that
 * looked straight down at the car, so a pop over the coin *was* a pop over the
 * coin on screen. From T7's chase camera the payer can be a coin two lengths
 * ahead, a ghost off to the left, or the car itself, and a number appearing in
 * the middle of the screen would not say which. So a pop is a sprite standing
 * where the money came from and it inherits the perspective — that is the whole
 * feedback: *that* thing paid.
 *
 * It is drawn with depth testing off, so a pop behind a barrier still reads.
 * A payout you missed seeing is a payout that did not teach you anything, and
 * unlike the ghost chain there is nothing here worth hiding: the money has
 * already been paid by the time a pop exists.
 *
 * ## The seam
 *
 * Everything that pays — `sim/lap.ts` at a checkpoint, `sim/coins.ts` at a
 * coin, `sim/contact.ts` at a boosted ghost — takes an optional `onPay` and
 * reports *where*. `sim/cash.ts` still refuses to know about position: it is
 * the tally, and the effects that decorate a payout belong to whoever awards
 * it. `loop.ts` is what joins the two sides, exactly as it does for the ghost
 * line and the ribbon.
 */

import * as THREE from "three";

/** `popups.lua:3-4` — seconds a pop lives, and the pixels it rises over that. */
const POP_LIFE = 1.5;
const POP_RISE = 50;

/** Height above the ground a pop starts at, in source pixels. */
const POP_BASE_Y = 26;

/** Cap height of the drawn text in world units, at `scale` 1. */
const POP_TEXT_HEIGHT = 6;

/** `popups.lua:83` — the ghost pop is the quiet one: two-thirds size, 0.6 alpha. */
const GHOST_SCALE = 2 / 3;
const GHOST_ALPHA = 0.6;

/** `popups.lua:88` — the wiggle, in radians and radians per second. */
const WIGGLE_AMOUNT = 0.08;
const WIGGLE_HZ = 6;

/**
 * Live pops beyond this are dropped oldest-first. A lap cannot plausibly pay
 * this many times inside 1.5s, so the cap only ever catches a runaway knob.
 */
const MAX_POPS = 32;

/** The HUD's cash green (`hud.css`'s `.hud-cash`), so the two read as one number. */
const POP_COLOR = "#7bf59a";

/** Canvas pixels the glyphs are rasterized at. Scaled down to world units. */
const FONT_PX = 64;

export interface PopupSpawn {
  /** World position of the payer, in source pixels. Centers, not corners. */
  readonly x: number;
  readonly z: number;
  readonly amount: number;
  /** A ghost hit's pop: smaller and dimmer, per `popups.lua`. */
  readonly ghost?: boolean;
}

export interface PopupView {
  /** Add this to the scene. Source pixels, same space as the track. */
  readonly object: THREE.Object3D;
  /**
   * Spawn one pop. Called from the fixed step (that is where a payout happens),
   * but aged on wall time — a pop is cosmetic, like the coins' bob and the
   * HUD's flash fade.
   */
  spawn(pop: PopupSpawn): void;
  /** Age, rise and fade every live pop. Once per rendered frame. */
  update(wallSeconds: number): void;
  /** Drop every live pop — a session restart, where the money is gone too. */
  clear(): void;
  dispose(): void;
}

interface Pop {
  readonly sprite: THREE.Sprite;
  readonly material: THREE.SpriteMaterial;
  /** Spawn pose, kept because the sprite's own position is rewritten each frame. */
  readonly x: number;
  readonly y: number;
  readonly z: number;
  readonly scale: number;
  readonly alphaMul: number;
  /** Wall seconds at spawn. */
  readonly born: number;
}

/** One rasterized `$N`, and the aspect its sprite has to be scaled to. */
interface Glyphs {
  readonly texture: THREE.CanvasTexture;
  readonly aspect: number;
}

export function createPopupView(): PopupView {
  const group = new THREE.Group();
  // Pops are drawn over everything, so they must not be depth-sorted against
  // it either — the group renders last, and nothing inside it writes depth.
  group.renderOrder = 10;

  /**
   * One texture per distinct amount. Payouts come from a handful of knobs, so
   * in practice this fills up with three or four entries and stops.
   */
  const glyphs = new Map<string, Glyphs>();

  /** Sprites are recycled: a pop's material only ever swaps its `map`. */
  const free: THREE.Sprite[] = [];
  let live: Pop[] = [];

  let wall = 0;

  function rasterize(text: string): Glyphs {
    const existing = glyphs.get(text);
    if (existing !== undefined) return existing;

    const canvas = document.createElement("canvas");
    const pad = Math.round(FONT_PX * 0.25);
    const font = `700 ${FONT_PX}px ui-monospace, SFMono-Regular, Menlo, monospace`;

    // Measured on a throwaway context: the canvas has to be sized before the
    // context it will actually be drawn with is configured.
    const measure = canvas.getContext("2d");
    if (measure === null) throw new Error("popups: no 2d context for text");
    measure.font = font;
    const width = Math.ceil(measure.measureText(text).width);

    canvas.width = width + pad * 2;
    canvas.height = FONT_PX + pad * 2;

    const ctx = canvas.getContext("2d");
    if (ctx === null) throw new Error("popups: no 2d context for text");
    ctx.font = font;
    ctx.textBaseline = "middle";
    ctx.textAlign = "center";
    const cx = canvas.width / 2;
    const cy = canvas.height / 2;
    // The Lua's one-pixel black shadow (`popups.lua:89`), scaled to the raster.
    const drop = Math.max(2, Math.round(FONT_PX / 16));
    ctx.fillStyle = "#000000";
    ctx.fillText(text, cx + drop, cy + drop);
    ctx.fillStyle = POP_COLOR;
    ctx.fillText(text, cx, cy);

    const texture = new THREE.CanvasTexture(canvas);
    texture.colorSpace = THREE.SRGBColorSpace;
    // Pops shrink hard with distance; without a mip chain the glyph edges
    // sparkle as the camera moves.
    texture.minFilter = THREE.LinearMipmapLinearFilter;
    texture.magFilter = THREE.LinearFilter;
    texture.generateMipmaps = true;

    const built: Glyphs = { texture, aspect: canvas.width / canvas.height };
    glyphs.set(text, built);
    return built;
  }

  function retire(pop: Pop): void {
    pop.sprite.visible = false;
    free.push(pop.sprite);
  }

  return {
    object: group,

    spawn({ x, z, amount, ghost = false }) {
      const { texture, aspect } = rasterize(`$${amount.toFixed(0)}`);

      const sprite = free.pop() ?? newSprite(group);
      const material = sprite.material;
      material.map = texture;
      material.needsUpdate = true;
      sprite.visible = true;

      const scale = ghost ? GHOST_SCALE : 1;
      const height = POP_TEXT_HEIGHT * scale;
      sprite.scale.set(height * aspect, height, 1);

      live.push({
        sprite,
        material,
        x,
        y: POP_BASE_Y,
        z,
        scale,
        alphaMul: ghost ? GHOST_ALPHA : 1,
        born: wall,
      });

      while (live.length > MAX_POPS) {
        const oldest = live.shift();
        if (oldest !== undefined) retire(oldest);
      }
    },

    update(wallSeconds) {
      wall = wallSeconds;
      if (live.length === 0) return;

      const kept: Pop[] = [];
      for (const pop of live) {
        const t = (wallSeconds - pop.born) / POP_LIFE;
        if (t >= 1) {
          retire(pop);
          continue;
        }
        // Linear rise and linear fade, `popups.lua:82-84`. The rise is in world
        // units here rather than screen pixels, which is the same number: the
        // 2D camera was 1:1 with source pixels.
        pop.sprite.position.set(pop.x, pop.y + t * POP_RISE, pop.z);
        pop.material.opacity = (1 - t) * pop.alphaMul;
        // Seeded on spawn x, so pops from a coin and from a ghost taken in the
        // same second are visibly separate objects rather than one moving mass.
        pop.material.rotation =
          Math.sin(wallSeconds * WIGGLE_HZ + pop.x) * WIGGLE_AMOUNT;
        kept.push(pop);
      }
      live = kept;
    },

    clear() {
      for (const pop of live) retire(pop);
      live = [];
    },

    dispose() {
      for (const pop of live) retire(pop);
      live = [];
      for (const sprite of free) sprite.material.dispose();
      free.length = 0;
      for (const { texture } of glyphs.values()) texture.dispose();
      glyphs.clear();
      group.clear();
    },
  };
}

function newSprite(group: THREE.Group): THREE.Sprite {
  const sprite = new THREE.Sprite(
    new THREE.SpriteMaterial({
      transparent: true,
      // Over everything: a pop behind a curb or a ghost still has to be read,
      // and it is gone in a second and a half either way.
      depthTest: false,
      depthWrite: false,
    }),
  );
  sprite.visible = false;
  group.add(sprite);
  return sprite;
}
