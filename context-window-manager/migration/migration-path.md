# Migration Path: Concrete PR Sequence

## Guiding Principles

1. **Ship value early**: Progressive disclosure delivers 84% savings without Dolt
2. **Feature-flag everything**: `KILO_EXPERIMENTAL_*` gates, rollback is one env var
3. **Independent tracks**: Features that don't need Dolt ship independently
4. **Small PRs**: Each PR is reviewable in one sitting (~300 lines target)
5. **Prove the pattern first**: Each PR builds confidence for the next one
6. **No surprises**: Open GitHub Discussion before the first architectural PR

## Track Overview

Three independent tracks that converge at Phase 6:

```
Track A: Progressive Disclosure (no Dolt, immediate value)
  PR-A1 → PR-A2 → PR-A3

Track B: Storage Abstraction (foundation, no new deps)
  PR-B1 → PR-B2 → PR-B3

Track C: Observability (lifecycle events, no Dolt)
  PR-C1 → PR-C2

                    ↓ converge ↓

Track D: Dolt Backend (opt-in, feature-flagged)
  PR-D1 → PR-D2 → PR-D3 → PR-D4
```

Tracks A, B, and C can run in parallel. Track D depends on B completing.

## Pre-Requisites (Before Any PR)

### GitHub Discussion

Open a Discussion (not Issue, not PR) to gauge team appetite:

```
Title: Discussion: Improving context window efficiency for long sessions

Body:
- Problem: GH#6442 + 25% context waste from tool outputs
- Proposed: Progressive disclosure (84% savings, no new deps)
- Future: Pluggable storage backend (optional, feature-flagged)
- Question: Would these PRs be welcome?
- Link: [Research](https://github.com/peterkc/kilocode/blob/research/context-window-manager/README.md)
```

This positions us as asking, not telling. If the team says "not interested,"
we haven't wasted PR effort. If they say "go ahead," we have implicit approval.

### Credibility Baseline

Before proposing architecture changes, ensure Phase 1 credibility PRs are merged:
- PR #6368 (Gemini thoughtSignature) — bot recommends merge
- At least 1-2 more small bug fixes

---

## Track A: Progressive Disclosure

**Goal**: 84% reduction in context tokens from tool output. No new dependencies.

### PR-A1: Smart summarizer for Read tool

**Flag**: `KILO_EXPERIMENTAL_SMART_SUMMARY`
**Files**: `tool/read.ts`, NEW `tool/summarizer/code.ts`
**Size**: ~200 lines changed, ~150 new
**Dependencies**: None

```
What changes:
- When read output > 1KB AND flag enabled:
  - Code files: summarize imports, exports, classes, functions, line ranges
  - Markdown: summarize headings, link count, code block count
  - JSON: summarize top-level keys, array lengths
  - Default: first 5 + last 5 lines with line count
- Summary replaces truncated head in conversation
- Full output still saved to temp file (existing behavior)
- metadata.tier = 1 | 2 added to tool result

Tests:
- Unit: summarizer produces expected output for each file type
- Integration: read tool returns summary when flag enabled, full output when disabled
```

### PR-A2: Smart summarizer for Bash tool

**Flag**: `KILO_EXPERIMENTAL_SMART_SUMMARY`
**Files**: `tool/bash.ts`, NEW `tool/summarizer/bash.ts`
**Size**: ~150 lines changed, ~200 new
**Dependencies**: PR-A1 (shares summarizer pattern)

```
What changes:
- When bash output > 1KB AND flag enabled:
  - Test output: pass/fail/skip counts, failed test names
  - Build output: success/fail, error count, first 3 errors
  - Git output: status summary, diff stats
  - Generic: exit code, first 3 + last 3 lines, error-containing lines
- Output classifier: regex-based type detection
- Same temp file fallback

Tests:
- Unit: classifier correctly identifies test/build/git/generic output
- Unit: each summarizer produces expected output
- Integration: bash tool returns summary when flag enabled
```

### PR-A3: Summary + ref for Grep, Glob, WebFetch

**Flag**: `KILO_EXPERIMENTAL_SMART_SUMMARY`
**Files**: `tool/grep.ts`, `tool/glob.ts`, `tool/webfetch.ts`, NEW `tool/summarizer/search.ts`, `tool/summarizer/web.ts`
**Size**: ~150 lines changed, ~200 new
**Dependencies**: PR-A1

```
What changes:
- Grep: match count by file distribution + top 5 matches
- Glob: file count + directory distribution (already small, may stay Tier 1)
- WebFetch: page title, heading count, word count estimate
- Lower Truncate.output threshold consideration (50KB → configurable)

Tests:
- Unit: each summarizer
- Integration: grep/webfetch return summaries when flag enabled
```

**Track A outcome**: All tool outputs > 1KB get structured summaries instead of
raw truncated heads. Measurable: token savings per session.

---

## Track B: Storage Abstraction

**Goal**: Extract StoragePort interface, wrap SQLite in adapter. No functional change.

### PR-B1: StoragePort interface + SQLiteAdapter (session/message only)

**Flag**: None (internal refactor, no behavior change)
**Files**: NEW `storage/port.ts`, NEW `storage/wire.ts`, NEW `storage/adapters/sqlite.ts`, `session/index.ts`, `session/message-v2.ts`
**Size**: ~300 new, ~200 changed
**Dependencies**: GitHub Discussion approval
**ADR**: [2001](https://github.com/peterkc/kilocode/blob/adr/2001-pluggable-storage-backend.md)

```
What changes:
- Define StoragePort interface (session + message + part CRUD)
- SQLiteAdapter wraps current Database.use() calls exactly
- StorageFactory.create() returns SQLiteAdapter (only option)
- session/index.ts: Session.create/get/list use StorageFactory.get()
- session/message-v2.ts: stream() delegates to adapter

Key constraint: ALL existing tests must pass unchanged.
The SQLiteAdapter is a thin wrapper — same sync behavior,
same data, same SQL. Just accessed through an interface.

Tests:
- Existing session tests pass unchanged (regression)
- New: StoragePort contract tests (run against SQLiteAdapter)
```

### PR-B2: Migrate remaining callers to StoragePort

**Flag**: None (internal refactor)
**Files**: `project/project.ts`, `share/share-next.ts`, `control/index.ts`, `permission/next.ts`, `session/todo.ts`, `session/revert.ts`, `worktree/index.ts`, `cli/cmd/import.ts`, `cli/cmd/stats.ts`
**Size**: ~400 changed (mechanical — `Database.use()` → `storage.*()`)
**Dependencies**: PR-B1

```
What changes:
- Each file's Database.use() calls → StorageFactory.get().method()
- StoragePort interface extended with project, share, control, permission, todo methods
- SQLiteAdapter extended with implementations for each

This is the "long tail" of mechanical refactoring. 9 files, ~34 call sites.
Each is a straightforward swap.

Tests:
- ALL existing tests pass unchanged
```

### PR-B3: Async StoragePort (prepare for wire-protocol backends)

**Flag**: None (internal refactor)
**Files**: `storage/port.ts`, `storage/adapters/sqlite.ts`, all callers (~11 files)
**Size**: ~500 changed (mechanical — add `await` to ~52 call sites)
**Dependencies**: PR-B2

```
What changes:
- StoragePort methods become async (return Promise<T> instead of T)
- SQLiteAdapter wraps sync BunDatabase calls in Promise.resolve()
- All callers add await (mechanical, AST-transformable)
- No functional change — same sync SQLite under the hood

This is the biggest single PR in the migration. Consider splitting
into sub-PRs by module (session → project → supporting).

Tests:
- ALL existing tests pass unchanged
- Async behavior verified (no race conditions introduced)
```

**Track B outcome**: All 52 Database.use() calls go through StoragePort.
Any backend can be plugged in via wire.ts. SQLite behavior is identical.

---

## Track C: Observability

**Goal**: Lifecycle events for conversation tracing. No Dolt needed.

### PR-C1: Plugin.emit() + session lifecycle events

**Flag**: `KILO_EXPERIMENTAL_LIFECYCLE_EVENTS`
**Files**: `plugin/index.ts`, `session/index.ts`, `session/prompt.ts`
**Size**: ~200 new, ~100 changed
**Dependencies**: None

```
What changes:
- Add Plugin.emit() (parallel dispatch, fire-and-forget) alongside Plugin.trigger()
- Add session.start event (fires on Session.createNext, includes source detection)
- Add session.end event (fires on session close/archive)
- Add session.stop event (fires on clean agent completion)
- Add turn.start / turn.end events (fires at prompt entry/exit)

Tests:
- Plugin.emit() dispatches to all registered handlers in parallel
- Lifecycle events fire with correct payload
- Events don't slow down the main loop (parallel, non-blocking)
```

### PR-C2: Tool and compaction lifecycle events

**Flag**: `KILO_EXPERIMENTAL_LIFECYCLE_EVENTS`
**Files**: `session/prompt.ts`, `session/compaction.ts`, `session/processor.ts`
**Size**: ~150 new, ~100 changed
**Dependencies**: PR-C1

```
What changes:
- Add tool.pre / tool.post events (unified — fires for success AND error)
- Add compact.pre / compact.post events (with summary text and prune stats)
- Add context.update event (fires at finish-step with token counts)
- Normalize MCP tool output in tool.post (consistent shape)

Tests:
- tool.post fires for both success and error paths
- compact.post includes summary and prunedParts count
- context.update includes zone classification
```

**Track C outcome**: Plugins can build a complete conversation trace. The
existing 13 transform hooks are unchanged — lifecycle events are additive.

---

## Track D: Dolt Backend

**Goal**: Optional Dolt storage with versioning, branching, team sharing.

### PR-D1: DoltAdapter + DualWriteAdapter

**Flag**: `KILO_EXPERIMENTAL_DOLT`
**Files**: NEW `storage/adapters/dolt.ts`, NEW `storage/adapters/dual-write.ts`, NEW `storage/dolt/install.ts`, NEW `storage/dolt/server.ts`, `storage/wire.ts`, `flag/flag.ts`
**Size**: ~800 new, ~50 changed
**Dependencies**: Track B complete (PR-B3), GitHub Discussion approval
**ADR**: [2001](https://github.com/peterkc/kilocode/blob/adr/2001-pluggable-storage-backend.md), [3001](https://github.com/peterkc/kilocode/blob/adr/3001-feature-flag-rollout.md)

```
What changes:
- DoltAdapter: mysql2 connection pool, implements StoragePort
- DualWriteAdapter: writes to both, reads from primary
- DoltInstall: binary resolution (PATH → managed → download)
- DoltServer: lifecycle management (start, stop, health check, port allocation)
- Flag: KILO_EXPERIMENTAL_DOLT, KILO_EXPERIMENTAL_DOLT_DUAL_WRITE
- wire.ts: route to DualWriteAdapter when flag enabled

Stage 1 rollout: SQLite primary (reads), Dolt shadow (writes only).

Tests:
- DoltAdapter passes StoragePort contract tests (same as SQLite)
- DualWriteAdapter correctly writes to both, reads from primary
- DoltInstall finds system binary or downloads
- DoltServer starts/stops/health-checks correctly
- Integration: session CRUD works through DualWriteAdapter
```

### PR-D2: Per-project databases + Silver views

**Flag**: `KILO_EXPERIMENTAL_DOLT`
**Files**: `storage/adapters/dolt.ts`, NEW `storage/schema/views.sql`, NEW `storage/dolt/database.ts`
**Size**: ~400 new, ~100 changed
**Dependencies**: PR-D1
**ADR**: [2002](https://github.com/peterkc/kilocode/blob/adr/2002-per-project-database.md)

```
What changes:
- ensureProjectDatabase(): create kilo_{prefix} on first project use
- kilo_meta database: project registry, control accounts
- Silver views: v_active_context, v_tool_calls, v_session_timeline
- DoltAdapter.streamMessages() uses v_active_context (server-side filtering)
- kilo db status command

Tests:
- Database creation for new project
- Silver views return correct results
- streamMessages() via view matches filterCompacted() output
```

### PR-D3: Tool output storage + progressive disclosure integration

**Flag**: `KILO_EXPERIMENTAL_DOLT` + `KILO_EXPERIMENTAL_SMART_SUMMARY`
**Files**: `storage/adapters/dolt.ts`, `tool/tool.ts`, NEW `storage/tables/tool_output.ts`, NEW `tool/retrieve.ts`
**Size**: ~300 new, ~100 changed
**Dependencies**: PR-D2, Track A complete
**ADR**: [2003](https://github.com/peterkc/kilocode/blob/adr/2003-progressive-disclosure-tool-output.md)

```
What changes:
- tool_output table in per-project database
- Tier 2/3 outputs stored in Dolt (replaces temp files when Dolt available)
- retrieve tool: query stored outputs by ref ID
- Integration: tool/tool.ts routes to Dolt storage when available,
  falls back to temp files on SQLite

Tests:
- Tier 2 output stored in Dolt, retrievable by ref
- retrieve tool returns correct content with offset/limit
- Fallback: SQLite uses temp files (existing behavior)
```

### PR-D4: Session branching + Gold layer

**Flag**: `KILO_EXPERIMENTAL_DOLT_BRANCHING`
**Files**: `storage/adapters/dolt.ts`, `session/compaction.ts`, `session/revert.ts`, NEW `storage/tables/session_summary.ts`
**Size**: ~400 new, ~200 changed
**Dependencies**: PR-D3

```
What changes:
- Session branches: create on session.start, merge on session.end
- Tool branches: branch-per-tool-call for Tier 2/3 outputs
- Gold layer: session_summary table, persist on compaction
- Compaction: actual DELETE of tool outputs + branch pruning + GC
- Revert: DOLT_CHECKOUT replaces hand-rolled revert.ts logic
- Auto-commit: configurable cadence (per-turn, per-N-turns)

Tests:
- Session branch created/merged correctly
- Tool branches created/deleted on compaction
- Gold summary persisted and retrievable
- Revert via DOLT_CHECKOUT matches current revert behavior
```

---

## PR Dependency Graph

```
Track A (no deps):        A1 → A2 → A3
Track B (needs Discussion): B1 → B2 → B3
Track C (no deps):        C1 → C2

Track D (needs B):        D1 → D2 → D3 → D4
                          ↑              ↑
                          B3             A3
```

## Timeline Estimate (Not Calendar, Just Ordering)

| Order | PR | Track | Size | Depends On |
|-------|-----|-------|------|------------|
| 1 | Discussion | — | — | Credibility PRs merged |
| 2 | PR-A1 | A | ~350 lines | None |
| 3 | PR-C1 | C | ~300 lines | None |
| 4 | PR-A2 | A | ~350 lines | A1 |
| 5 | PR-B1 | B | ~500 lines | Discussion approval |
| 6 | PR-A3 | A | ~350 lines | A1 |
| 7 | PR-C2 | C | ~250 lines | C1 |
| 8 | PR-B2 | B | ~400 lines | B1 |
| 9 | PR-B3 | B | ~500 lines | B2 |
| 10 | PR-D1 | D | ~850 lines | B3 |
| 11 | PR-D2 | D | ~500 lines | D1 |
| 12 | PR-D3 | D | ~400 lines | D2, A3 |
| 13 | PR-D4 | D | ~600 lines | D3 |

**Total**: ~5,350 lines across 13 PRs.

Track A (PRs 2, 4, 6) ships value immediately — no architectural discussion needed.
Track C (PRs 3, 7) ships observability — also no architectural discussion needed.
Track B (PRs 5, 8, 9) requires Discussion approval — it's the architectural foundation.
Track D (PRs 10-13) is the Dolt integration — requires B + team confidence.

## Feature Flag Progression

| Flag | Default | Activated By |
|------|---------|-------------|
| `KILO_EXPERIMENTAL_SMART_SUMMARY` | OFF | PR-A1 |
| `KILO_EXPERIMENTAL_LIFECYCLE_EVENTS` | OFF | PR-C1 |
| `KILO_EXPERIMENTAL_DOLT` | OFF | PR-D1 |
| `KILO_EXPERIMENTAL_DOLT_DUAL_WRITE` | ON (when Dolt enabled) | PR-D1 |
| `KILO_EXPERIMENTAL_DOLT_READ_FROM_DOLT` | OFF | PR-D2 (flip to test) |
| `KILO_EXPERIMENTAL_DOLT_BRANCHING` | OFF | PR-D4 |
| `KILO_EXPERIMENTAL_DOLT_SHARING` | OFF | Future |

### Promotion Path

```
EXPERIMENTAL_SMART_SUMMARY → positive feedback → remove flag, always on
EXPERIMENTAL_LIFECYCLE_EVENTS → plugins use it → remove flag, always on
EXPERIMENTAL_DOLT → stable metrics → default ON, add DISABLE_DOLT
```

## Risk Matrix

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| Team rejects Discussion | Medium | Track B/D blocked | Track A/C still ship value |
| Async refactor (PR-B3) introduces bugs | Low | Regression | Mechanical transform, comprehensive test suite |
| Dolt download fails (firewall, air-gap) | Low | Dolt unavailable | SQLite fallback, DISABLE_DOLT_DOWNLOAD flag |
| DualWriteAdapter latency visible to users | Low | UX degradation | Secondary write is async best-effort |
| Port conflict with existing Dolt | Medium | Server won't start | Dynamic port allocation + coexistence detection |
| Silver views produce different results than filterCompacted() | Medium | Context correctness | Parallel comparison testing in PR-D2 |
| Team wants Postgres not Dolt | Low | Architecture change | StoragePort supports both — add PostgresAdapter |

## Success Metrics

| Metric | Target | Measured At |
|--------|--------|-------------|
| Context token savings | ≥80% reduction from tool output | After Track A merged |
| Turns before compaction | ≥2x increase | After Track A merged |
| StoragePort parity | 100% existing tests pass | After Track B merged |
| DualWrite consistency | 0 verification mismatches | After Track D PR-D1 |
| Dolt query latency | <10ms p95 for session queries | After Track D PR-D2 |
| Adoption (Dolt flag) | ≥10 users enable `EXPERIMENTAL_DOLT` | 4 weeks after PR-D1 |
