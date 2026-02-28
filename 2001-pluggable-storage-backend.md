---
status: Proposed
date: 2026-02-28
category: Architecture
deciders: [peterkc]
tags: [storage, dolt, sqlite, ports-and-adapters, hexagonal]
---

# ADR 2001: Pluggable Storage Backend via Ports & Adapters

## Context

Kilo Code uses SQLite (via Drizzle ORM) as its only storage backend. All 52
`Database.use()` calls across 11 files go through a single `BunDatabase` singleton
(`storage/db.ts`). This works for single-user local development but prevents:

- Server-side query filtering (SQLite is in-process — all data loads into JS heap)
- Versioned conversation history (no time-travel, no diff)
- Team sharing (file-based, single machine)
- Concurrent session isolation (WAL lock contention)

GH#6442 demonstrates the structural limit: 8.1GB footprint, 85MB live data,
80:1 waste ratio from in-process re-hydration.

## Decision Drivers

- Must not break existing SQLite users (zero-config default)
- Dolt (MySQL-wire-compatible) offers versioning, branching, server mode
- Postgres needed for team/cloud deployments
- ckd project proves the Ports & Adapters pattern works for storage swapping
- `Database.use()` is already a natural abstraction boundary

## Considered Options

### Option 1: Direct SQLite→Dolt Replacement

Replace `BunDatabase` with `mysql2` client. All code uses Dolt.

- Good: Simplest implementation
- Bad: No fallback for users without Dolt
- Bad: Breaking change for all existing installs
- Bad: No path to Postgres or other backends

### Option 2: Drizzle Dialect Swap (SQLite→MySQL)

Keep Drizzle ORM, swap the dialect driver from `bun-sqlite` to `mysql2`.

- Good: Minimal code change (Drizzle abstracts most SQL differences)
- Bad: Still single-backend (just a different one)
- Bad: Schema differences between SQLite and MySQL need handling
- Bad: No multi-backend coexistence

### Option 3: StoragePort Interface with Adapters [Chosen]

Define a `StoragePort` interface. Implement `SQLiteAdapter`, `DoltAdapter`,
`PostgresAdapter`. Composition root (`wire.ts`) selects adapter from config.

- Good: Each backend implements exactly what it supports
- Good: Optional capabilities via interface probing (ckd pattern)
- Good: SQLite remains default (zero-config, zero-dependency)
- Good: DualWriteAdapter enables safe migration between backends
- Good: New backends can be added without touching application code
- Neutral: 16 new files, 34 modified (mechanical refactor for most)
- Bad: Async refactor required (~52 call sites for Dolt wire protocol)

## Decision

**Option 3**: StoragePort interface with adapter pattern.

### Interface Hierarchy

```
StoragePort (Base)         — Required: CRUD, transaction, lifecycle
VersionedStorage           — Optional: commit, asOf, diff, log
BranchingStorage           — Optional: branch, checkout, merge, gc
SearchableStorage          — Optional: vectorSearch, textSearch
HookableStorage            — Optional: onWrite, onRead lifecycle hooks
```

Callers use type guards to check capabilities:
```typescript
if (isBranching(storage)) {
  await storage.createBranch(`session/${id}`)
}
```

### Composition Root

```typescript
// storage/wire.ts
switch (config.backend) {
  case "sqlite":   return new SQLiteAdapter(config)
  case "dolt":     return new DoltAdapter(config)
  case "postgres": return new PostgresAdapter(config)
}
```

## Consequences

### Positive

- SQLite users: zero change (default adapter wraps current behavior)
- Dolt users: server-side filtering, versioning, branching, team sharing
- Postgres users: team deployments without Dolt dependency
- Future backends: implement StoragePort, add to wire.ts

### Negative

- Async refactor: 52 `Database.use()` calls become `await storage.*()` calls
- Testing: each adapter needs its own integration test suite
- Complexity: 3 adapters to maintain instead of 1 implementation

### Neutral

- DualWriteAdapter enables gradual migration (feature-flagged)
- SQLiteAdapter may eventually become unmaintained (but serves as zero-dep fallback)

## Related

- [Research: pluggable-storage.md](https://github.com/peterkc/kilocode/blob/research/context-window-manager/target-architecture/pluggable-storage.md)
- [Research: component-map.md](https://github.com/peterkc/kilocode/blob/research/context-window-manager/target-architecture/component-map.md)
- [Inspiration: ckd hexagonal architecture](https://github.com/peterkc/ck-dolt)
- ADR 2002: Per-Project Database (multi-tenant schema)
- ADR 3001: Feature Flags for Gradual Rollout
