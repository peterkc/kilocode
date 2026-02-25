# Kilo Code Issue Tracking (Beads)

Orphan branch for beads/Dolt issue database (peterkc fork).

## Relationship

- Orphan branch `beads` of peterkc/kilo
- Mounted as worktree at `.beads/` in main repo root (required by bd CLI)
- Excluded via .gitignore (committed to origin/dev)

## Setup

```bash
bd init  # creates Dolt database in .beads/
```
