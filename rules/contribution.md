# Contribution Rules

## Branch Strategy

Always branch from `upstream/main` for PRs. Never base on `origin/main` (has .gitignore divergence).

```bash
git fetch upstream && git checkout -b fix/name upstream/main
```

## kilocode_change Markers

When modifying shared (upstream) files, tag changes:
- Single line: `// kilocode_change`
- Block: `// kilocode_change start` ... `// kilocode_change end`
- Kilo-specific dirs (`packages/opencode/src/kilocode/`): no markers needed

## Issue-First Policy

All PRs must reference an existing upstream issue. Check with `gh issue view <N> --repo Kilo-Org/kilocode`.

## Rubric

Score candidates with ADR-4001 before adding to Phase 1 (kc-934). Threshold: >= 6.
