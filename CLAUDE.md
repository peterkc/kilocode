# Kilo Code Architecture Decision Records

Orphan branch for ADRs (peterkc fork).

In fork context, ADRs live on orphan branches to avoid polluting upstream diffs.
Our decisions reference ACF/AHP concepts that upstream doesn't need to see.

## Index

| ADR  | Title                                          | Status   | Category     |
| ---- | ---------------------------------------------- | -------- | ------------ |
| 2001 | Pluggable Storage Backend (Ports & Adapters)   | Proposed | Architecture |
| 2002 | Per-Project Database on Shared Dolt Server     | Proposed | Architecture |
| 2003 | Progressive Disclosure for Tool Output         | Proposed | Architecture |
| 3001 | Feature Flags for Gradual Dolt Rollout         | Proposed | Execution    |
| 4001 | Issue Selection Rubric for Upstream Contrib     | Accepted | Process      |

## Categories

| Range     | Category     | Count |
| --------- | ------------ | ----- |
| 2000-2999 | Architecture | 3     |
| 3000-3999 | Execution    | 1     |
| 4000-4999 | Process      | 1     |

## Relationship

- Orphan branch `adr` of peterkc/kilocode
- Mounted as worktree at `.agents/adr/` in main repo
- Excluded via .gitignore (committed to origin/main, not upstreamed)

## Workflow

```bash
cd .agents/adr/
git add <files>
git commit -m "adr: ..."
git push origin adr
```

## Referencing in Upstream PRs

```markdown
Design rationale: [ADR-2001](https://github.com/peterkc/kilocode/blob/adr/2001-pluggable-storage-backend.md)
```
