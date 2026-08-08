import js from "@eslint/js";
import globals from "globals";
import tseslint from "typescript-eslint";

/**
 * The load-bearing rule of this codebase is the one-way arrow: `sim/` imports
 * nothing from `render/`. That is what keeps `sim/` pure, testable, and
 * portable. Encoded here so it cannot be violated by accident.
 */
const SIM_IS_PURE = {
  patterns: [
    {
      group: [
        "three",
        "three/*",
        "lil-gui",
        "**/render/**",
        "**/hud/**",
        "../render/*",
        "../hud/*",
      ],
      message:
        "sim/ is pure: no three.js, no lil-gui, no render/ or hud/ imports. Pass plain data across the seam instead.",
    },
  ],
};

export default tseslint.config(
  { ignores: ["dist/**", "node_modules/**"] },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    files: ["**/*.ts"],
    languageOptions: {
      globals: { ...globals.browser },
      parserOptions: { projectService: true, tsconfigRootDir: import.meta.dirname },
    },
  },
  {
    files: ["src/sim/**/*.ts"],
    rules: { "no-restricted-imports": ["error", SIM_IS_PURE] },
  },
);
