# Kilocode Fork — Claude Code Configuration

Orphan branch `claude` of peterkc/kilocode. Mounted at `.claude/` via worktree.

## Contents

- `rules/` — Always-on behavioral constraints for kilocode work
- `skills/` — On-demand capabilities

## Relationship

- Fork-specific: invisible to upstream Kilo-Org/kilocode
- Excluded via .gitignore (committed to origin/main)
- Claude Code auto-discovers `.claude/rules/` and `.claude/skills/`

## Future

When AHP is ready, migrate to `.agents/{rules,skills}`. Kilocode's skill discovery already scans `.agents/skills/`.
