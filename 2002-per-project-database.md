---
status: Proposed
date: 2026-02-28
category: Architecture
deciders: [peterkc]
tags: [storage, dolt, multi-tenant, isolation, team-sharing]
---

# ADR 2002: Per-Project Database on Shared Dolt Server

## Context

Kilo stores all projects in a single SQLite file (`kilo.db`). With the move to
Dolt (ADR 2001), we need to decide how to organize data across multiple projects.
Projects are identified by git root-commit SHA. Sessions are scoped to projects
via FK. The question is whether Dolt should use one database or many.

ACF's beads system (ADR-2007) faced the same decision and chose per-project
databases on a shared server (`acf_beads`, `agx_beads`, `ckd_beads`).

## Decision Drivers

- Per-project branching isolation (Dolt branches are database-scoped)
- Selective team sharing (`dolt push` per project, not all-or-nothing)
- Independent GC (one project's cleanup shouldn't affect others)
- Operational simplicity (one server process, not per-project)
- ACF's proven pattern (ADR-2007: 3 repos, 1 server, 0 port sprawl)

## Considered Options

### Option 1: Shared Database with project_id Column

One `kilo_data` database. All tables have `project_id` columns.

- Good: Simplest setup, matches current SQLite model
- Good: Cross-project queries are natural JOINs
- Bad: Branches are database-scoped — can't isolate project branches
- Bad: `dolt push` shares ALL projects (privacy concern for teams)
- Bad: GC affects all projects simultaneously

### Option 2: Per-Project Database on Shared Server [Chosen]

Each project gets `kilo_{prefix}` database. One `kilo_meta` for registry.

- Good: Independent branching, GC, push/pull per project
- Good: Clean lifecycle (DROP DATABASE removes everything)
- Good: Proven pattern (ACF ADR-2007)
- Good: Adding a project = CREATE DATABASE (~50ms), not a new process
- Neutral: Cross-project queries need multi-database JOIN (rare)
- Bad: More databases = more Dolt metadata overhead

### Option 3: Per-Project Server Process

Each project runs its own Dolt server on a different port.

- Good: Complete isolation
- Bad: Port sprawl (10 projects = 10 ports)
- Bad: Resource waste (~130MB RSS per process)
- Bad: Operational nightmare (ACF learned this with 6 servers, ADR-2007)

## Decision

**Option 2**: Per-project database on shared Dolt server.

### Naming Convention

```
kilo_{first-8-chars-of-root-commit-sha}
kilo_meta     — server-level: project registry, OAuth accounts
kilo_global   — non-git directories (fallback project)
```

### Branch Naming Within Each Database

```
main                        — committed state, Gold layer (team-shared)
session/{session_id}        — per-session isolation
tool/{call_id}              — per-tool-call (progressive disclosure)
subagent/{agent_id}         — per-subagent isolation
share/{share_id}            — published snapshots
```

### Team Sharing Model

Only `main` branch gets pushed. Active sessions stay local.

| Layer | Pushed? | Contains |
|-------|---------|----------|
| Gold (session_summary) | Yes | What was learned/decided |
| Silver (views) | N/A | Computed on demand |
| Bronze (messages, parts) | No | Personal conversation history |
| Tool outputs | No | Heavy data, session-specific |

## Consequences

### Positive

- Per-project isolation for branching, GC, and sharing
- Team sharing is naturally scoped (push one project, not all)
- Clean project removal (DROP DATABASE)
- Concurrent sessions on different branches (no WAL contention)

### Negative

- Database creation overhead per new project (~50ms, amortized)
- Cross-project queries are more complex (multi-DB JOIN)
- More Dolt metadata per database

### Neutral

- `kilo_meta` acts as a registry — similar to ACF's project table in traces DB
- SQLite adapter ignores this (single file, project_id FK — unchanged)

## Related

- [Research: multi-tenant.md](https://github.com/peterkc/kilocode/blob/research/context-window-manager/target-architecture/multi-tenant.md)
- [ACF ADR-2007: Dolt Server Consolidation](https://github.com/peterkc/acf/blob/main/adr/2007-dolt-server-consolidation.md)
- ADR 2001: Pluggable Storage Backend
