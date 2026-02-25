# Orphan Branch Layout

| Directory | Branch | Purpose |
|-----------|--------|---------|
| `.claude/` | `claude` | Rules, skills (Claude Code discovery) |
| `.agents/specs/` | `specs` | Spec-driven development |
| `.agents/research/` | `research` | Research artifacts |
| `.agents/adr/` | `adr` | Architecture decisions |
| `.beads/` | `beads` | Issue tracking (Dolt) |

All excluded via .gitignore (committed to origin/main, not upstreamed).

## References in PRs

Link to orphan branches in upstream PRs:
```markdown
[ADR-4001](https://github.com/peterkc/kilocode/blob/adr/4001-issue-selection-rubric.md)
[Research](https://github.com/peterkc/kilocode/blob/research/kilo-cli-rebuild-analysis/README.md)
```
