# Beads — Kilocode Fork

Issue prefix: `kc-`
Database: shared Dolt server port 3309, database `beads_kc`

## Phase Epics

| Epic | Phase | Status |
|------|-------|--------|
| kc-934 | Phase 1: Credibility (bug fixes) | Ready |
| kc-5te | Phase 2: Plugins (AHP concepts) | Blocked by kc-934 |
| kc-870 | Phase 3: Core proposals | Blocked by kc-5te |

## Workflow

```bash
bd ready                    # What's unblocked
bd show kc-934              # Phase 1 details
bd update <id> --claim      # Start work
bd close <id>               # Complete
```
