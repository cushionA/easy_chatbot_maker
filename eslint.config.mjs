// Flat config (ESLint 9). Lints the TypeScript stack only; Python/C# have their own
// tooling (ruff/mypy, dotnet format) and the spike is throwaway. Formatting is owned by
// Prettier, so eslint-config-prettier is applied last to disable stylistic overlap.
// See docs/conventions/typescript.md and react.md for the rationale behind each rule.
import js from "@eslint/js";
import vitest from "@vitest/eslint-plugin";
import prettier from "eslint-config-prettier";
import jsxA11y from "eslint-plugin-jsx-a11y";
import playwright from "eslint-plugin-playwright";
import react from "eslint-plugin-react";
import reactHooks from "eslint-plugin-react-hooks";
import simpleImportSort from "eslint-plugin-simple-import-sort";
import tseslint from "typescript-eslint";

export default tseslint.config(
  {
    // Not linted here: deps, build output, throwaway spike, and the legacy/non-TS stacks.
    ignores: [
      "**/node_modules/**",
      "**/dist/**",
      "**/build/**",
      "**/coverage/**",
      "**/.next/**",
      "spike/**",
      "backend/**",
      "embedding/**",
    ],
  },

  js.configs.recommended,

  // Type-aware rules apply only to real implementation code. `projectService` finds each
  // package's tsconfig (which extends tsconfig.base.json) automatically.
  {
    files: ["{apps,workers,packages}/**/*.{ts,tsx}"],
    extends: [...tseslint.configs.recommendedTypeChecked, ...tseslint.configs.stylisticTypeChecked],
    languageOptions: {
      parserOptions: {
        projectService: true,
        tsconfigRootDir: import.meta.dirname,
      },
    },
    plugins: { "simple-import-sort": simpleImportSort },
    rules: {
      "simple-import-sort/imports": "error",
      "simple-import-sort/exports": "error",
      "@typescript-eslint/no-explicit-any": "error",
      "@typescript-eslint/no-floating-promises": "error",
      "@typescript-eslint/no-misused-promises": "error",
      "@typescript-eslint/switch-exhaustiveness-check": "error",
      "@typescript-eslint/consistent-type-imports": ["error", { fixStyle: "inline-type-imports" }],
      "no-console": ["warn", { allow: ["warn", "error"] }],
      eqeqeq: ["error", "smart"],
    },
  },

  // React (frontend) layered on top of the type-aware block for apps/web.
  // jsx-a11y enforces the accessibility minimums documented in react.md.
  {
    files: ["apps/web/**/*.{ts,tsx}"],
    plugins: { react, "react-hooks": reactHooks, "jsx-a11y": jsxA11y },
    languageOptions: { parserOptions: { ecmaFeatures: { jsx: true } } },
    settings: { react: { version: "detect" } },
    rules: {
      ...react.configs.flat.recommended.rules,
      ...jsxA11y.flatConfigs.recommended.rules,
      "react-hooks/rules-of-hooks": "error",
      "react-hooks/exhaustive-deps": "warn",
      "react/react-in-jsx-scope": "off",
      "react/prop-types": "off",
    },
  },

  // Vitest unit/integration tests.
  {
    files: ["**/*.{test,spec}.{ts,tsx}"],
    plugins: { vitest },
    languageOptions: { globals: vitest.environments.env.globals },
    settings: { vitest: { typecheck: true } },
    rules: {
      "vitest/no-focused-tests": "error",
      "vitest/no-disabled-tests": "warn",
      "vitest/no-identical-title": "error",
      "vitest/valid-expect": "error",
      "vitest/expect-expect": "warn",
    },
  },

  // Playwright E2E tests.
  {
    files: ["**/e2e/**/*.{ts,tsx}", "**/*.e2e.{ts,tsx}"],
    plugins: { playwright },
    rules: {
      "playwright/no-focused-test": "error",
      "playwright/no-skipped-test": "warn",
      "playwright/missing-playwright-await": "error",
      "playwright/no-wait-for-timeout": "warn",
    },
  },

  // Plain JS (config files, scripts): no type-aware rules.
  {
    files: ["**/*.{js,mjs,cjs}"],
    extends: [tseslint.configs.disableTypeChecked],
    rules: { "no-undef": "off" },
  },

  prettier,
);
