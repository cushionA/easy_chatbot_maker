// Conventional Commits validation. Mirrors the type table in CONTRIBUTING.md (adds `security`).
// Wired as a pre-commit `commit-msg` hook; install with `pre-commit install -t commit-msg`
// (included in `make install-tooling`). Subjects may be Japanese, hence the relaxed length.
export default {
  extends: ["@commitlint/config-conventional"],
  rules: {
    "type-enum": [
      2,
      "always",
      [
        "feat",
        "fix",
        "refactor",
        "test",
        "docs",
        "chore",
        "ci",
        "perf",
        "security",
        "build",
        "revert",
        "style",
      ],
    ],
    "header-max-length": [2, "always", 120],
  },
};
