---
status: Proposed
date: 2026-02-28
category: Execution
deciders: [peterkc]
tags: [migration, feature-flags, rollout, dolt, coexistence]
---

# ADR 3001: Feature Flags for Gradual Dolt Rollout

## Context

The beads project switched from SQLite embedded mode to Dolt server mode in one
release. Users hit installation failures, server startup issues, lock file
corruption, and schema migration errors with no rollback path. The lesson:
infrastructure changes must coexist with the existing system during rollout.

Kilo already has a mature feature flag system (`flag/flag.ts`) using env vars
with `KILO_EXPERIMENTAL_*` (opt-in) and `KILO_DISABLE_*` (opt-out) conventions.
The master switch `KILO_EXPERIMENTAL` enables all experimental features at once.

## Decision Drivers

- Beads lesson: abrupt SQLite→Dolt switch caused user-facing failures
- Kilo's existing flag pattern (`KILO_EXPERIMENTAL_*`) is proven and understood
- Both backends must coexist during rollout (no data loss on rollback)
- Progressive disclosure and context awareness can ship without Dolt
- Metrics needed to validate Dolt stability before making it default

## Considered Options

### Option 1: Config-Only Backend Selection

`storage.backend: "dolt"` in config. No dual-write, no gradual rollout.

- Good: Simple — one setting, one backend
- Bad: No safety net (data only in Dolt, if Dolt fails = data loss)
- Bad: No gradual rollout (all-or-nothing)
- Bad: Repeats beads mistake

### Option 2: Feature Flags with DualWriteAdapter [Chosen]

Staged rollout using `KILO_EXPERIMENTAL_DOLT` flags. DualWriteAdapter writes to
both backends simultaneously. Primary/secondary role determined by flag state.

- Good: Both backends always have complete data
- Good: Rollback is one env var change
- Good: Verification command (`kilo db verify`) catches inconsistencies
- Good: Metrics collection informs promotion decisions
- Good: Independent features (progressive disclosure) ship without Dolt
- Neutral: Dual-write adds ~10% latency (secondary write is best-effort)
- Bad: More complex implementation than single-backend

### Option 3: Blue-Green with Migration Script

Run SQLite until migration script converts to Dolt. No coexistence.

- Good: Clean cutover
- Bad: Migration script must handle all edge cases
- Bad: No rollback without re-running reverse migration
- Bad: Users must schedule downtime for migration

## Decision

**Option 2**: Feature flags with DualWriteAdapter.

### Five Rollout Stages

```
Stage 1: EXPERIMENTAL_DOLT           SQLite primary, Dolt shadow
Stage 2: + READ_FROM_DOLT            Dolt primary, SQLite shadow
Stage 3: Dolt default                DISABLE_DOLT to opt out
Stage 4: SQLite deprecated           Migration tool, warnings
Stage 5: SQLite as zero-dep fallback May stay indefinitely
```

### DualWriteAdapter

```typescript
class DualWriteAdapter implements StoragePort {
  constructor(private primary: StoragePort, private secondary: StoragePort) {}

  async createSession(session) {
    await this.primary.createSession(session)
    this.secondary.createSession(session).catch(log.warn)  // best-effort
  }

  async streamMessages(sessionID) {
    return this.primary.streamMessages(sessionID)  // always from primary
  }
}
```

### Independent Feature Tracks

| Feature | Needs Dolt? | Flag |
|---------|-------------|------|
| Progressive Disclosure | No | `EXPERIMENTAL_PROGRESSIVE_DISCLOSURE` |
| Context Awareness | No | `EXPERIMENTAL_CONTEXT_AWARENESS` |
| Lifecycle Events | No | `EXPERIMENTAL_LIFECYCLE_EVENTS` |
| Dolt Backend | Yes | `EXPERIMENTAL_DOLT` |
| Branching | Yes | `EXPERIMENTAL_DOLT_BRANCHING` |
| Team Sharing | Yes | `EXPERIMENTAL_DOLT_SHARING` |

## Consequences

### Positive

- No data loss at any rollout stage (dual-write ensures both backends are current)
- Rollback is one env var (`KILO_EXPERIMENTAL_DOLT=false`)
- Features that don't need Dolt ship independently and earlier
- Metrics collected during dual-write validate Dolt stability

### Negative

- DualWriteAdapter adds implementation complexity
- Dual-write has ~10% latency overhead during coexistence stages
- Two codepaths to maintain during rollout period

### Neutral

- SQLite may remain as permanent zero-dep fallback (Stage 5)
- Config file (`kilo.json`) and env vars both work for flag control

## Related

- [Research: feature-flags.md](https://github.com/peterkc/kilocode/blob/research/context-window-manager/migration/feature-flags.md)
- [Beads: SQLite→Dolt migration lessons](https://github.com/peterkc/acf/blob/main/memory/MEMORY.md)
- ADR 2001: Pluggable Storage Backend
- ADR 2002: Per-Project Database
