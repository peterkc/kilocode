# Kilo Code Architecture Decision Records

Orphan branch for ADRs (peterkc fork).

In fork context, ADRs live on orphan branches to avoid polluting upstream diffs.
Our decisions reference ACF/AHP concepts that upstream doesn't need to see.

## Relationship

- Orphan branch `adr` of peterkc/kilo
- Mounted as worktree at `.agents/adr/` in main repo
- Excluded via .gitignore (committed to origin/dev)

## Workflow

```bash
git status
git add <files>
git commit -m "..."
git push origin adr
```
