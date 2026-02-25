# Kilo Code Specs Repository

Orphan branch for spec-driven development artifacts (peterkc fork).

## Relationship

- Orphan branch `specs` of peterkc/kilo
- Mounted as worktree at `.agents/specs/` in main repo
- Excluded via .gitignore (committed to origin/dev)
- Not present in upstream Kilo-Org/kilo

## Workflow

```bash
git status
git add <files>
git commit -m "..."
git push origin specs
```

## Accessing from Feature Branches

```bash
$(git worktree list | head -1 | awk '{print $1}')/.agents/specs/
```
