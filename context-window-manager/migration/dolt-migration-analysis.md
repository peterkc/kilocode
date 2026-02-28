# Dolt Migration Analysis — SQLite to Dolt in Kilo Code

Analysis of how to replace SQLite with Dolt server mode for Kilo Code's
conversation storage, informed by deep code mapping of the current architecture.

## Migration Surface Assessment

### What Makes This Feasible

1. **Single access point**: All DB access goes through `Database.use()` / `Database.transaction()`.
   Swapping the underlying client affects one file: `storage/db.ts`.

2. **Drizzle supports MySQL dialect**: Dolt is MySQL-wire-compatible. Drizzle has both
   `drizzle-orm/bun-sqlite` and `drizzle-orm/mysql2` drivers. Schema definitions need
   column type changes (TEXT -> VARCHAR, INTEGER -> INT) but the ORM abstractions stay.

3. **Only 7 callers**: The entire SQLite surface is 7 modules + 1 CLI tool. Each can be
   migrated independently.

4. **JSON columns are driver-agnostic**: Kilo stores most data as JSON text columns.
   Both SQLite and MySQL support this. Drizzle's `$type<T>()` annotation is pure TypeScript.

5. **Cascade deletes work in both**: FK ON DELETE CASCADE is standard SQL.

### What Changes

| Current (SQLite) | Target (Dolt) | Notes |
|-----------------|---------------|-------|
| `BunDatabase` (in-process) | `mysql2` client (wire protocol) | Async vs sync |
| `bun:sqlite` driver | `drizzle-orm/mysql2` driver | Different import |
| `text()` columns | `varchar(N)` or `text()` | MySQL needs lengths for indexed columns |
| `integer()` timestamps | `bigint()` timestamps | MySQL integer = 32-bit, need bigint for epoch ms |
| Synchronous transactions | Async transactions | Major refactor of `Database.transaction()` |
| WAL mode PRAGMA | N/A (server handles) | Simpler config |
| 64MB cache PRAGMA | Server-side config | `--query-parallelism`, `--max-connections` |
| `BunDatabase.run()` | Client query | No more raw PRAGMA calls |

### The Async Problem

This is the biggest migration obstacle. Kilo's `Database.use()` and `Database.transaction()`
are synchronous (BunDatabase is synchronous). Many callers depend on this:

```typescript
// Current: synchronous
Database.use((db) => db.select().from(MessageTable).where(...).all())

// Dolt: must be async (wire protocol)
await Database.use(async (db) => await db.select().from(MessageTable).where(...))
```

Every call site needs `async/await`. This is a ~100-site mechanical refactor.

**Mitigation options**:
1. **Bun's synchronous MySQL** — Bun has experimental sync MySQL bindings. Risky, not stable.
2. **Async refactor** — Clean but large. Touch every caller.
3. **Connection pool with sync wrapper** — Use a blocking pattern. Against Bun's design.
4. **Recommended**: Async refactor. It's mechanical, and Dolt's wire protocol benefits
   (server-side filtering, no heap allocation) only work with async I/O.

## Dolt-Specific Opportunities

### 1. Server-Side Filtering (Fix GH#6442 Root Cause)

Current: `stream()` loads all parts, `filterCompacted()` drops old ones in JS.

With Dolt:
```sql
-- Only fetch non-compacted parts for messages after the compaction boundary
SELECT p.id, p.data
FROM part p
JOIN message m ON p.message_id = m.id
WHERE m.session_id = ?
  AND m.time_created > (
    SELECT MAX(m2.time_created)
    FROM message m2
    JOIN part p2 ON p2.message_id = m2.id
    WHERE m2.session_id = ?
      AND JSON_EXTRACT(p2.data, '$.type') = 'compaction'
  )
ORDER BY m.time_created ASC, p.id ASC
```

Heavy tool outputs never cross the wire. The JS heap only sees what the LLM needs.

### 2. True Pruning (Actually Clear state.output)

Current: `prune()` sets a flag but keeps the data.

With Dolt:
```sql
-- Actually clear the output, Dolt preserves history via versioning
UPDATE part
SET data = JSON_SET(data, '$.state.output', NULL)
WHERE JSON_EXTRACT(data, '$.state.time.compacted') IS NOT NULL
  AND session_id = ?;

-- Can still recover via time-travel if needed
SELECT JSON_EXTRACT(data, '$.state.output')
FROM part AS OF 'abc123def'
WHERE id = ?;
```

Data is removed from the working set but recoverable via `AS OF` queries.
`CALL DOLT_GC()` reclaims storage when truly done.

### 3. Native Revert (Replace revert.ts)

Current: 40+ lines of hand-rolled revert logic + snapshot tracking.

With Dolt:
```sql
-- Revert to any point
CALL DOLT_CHECKOUT('session/abc123');
-- Or reset to a specific commit
CALL DOLT_RESET('--hard', 'commit_hash');
-- Diff what changed
SELECT * FROM dolt_diff('commit_before', 'commit_after', 'part');
```

The entire `revert.ts` file becomes a thin wrapper around Dolt procedures.

### 4. Branch-Per-Subagent (Session Isolation)

Current: `parent_id` FK links child sessions, but they share the same DB.

With Dolt:
```sql
-- Create isolated branch for subagent
CALL DOLT_BRANCH('subagent/explore-auth');
CALL DOLT_CHECKOUT('subagent/explore-auth');
-- Subagent writes to its branch
INSERT INTO message ... ;
INSERT INTO part ... ;
-- Merge results back (or just read from branch)
CALL DOLT_MERGE('subagent/explore-auth');
-- Or drop if not needed
CALL DOLT_BRANCH('-D', 'subagent/explore-auth');
```

### 5. Context as SQL Views (The Git DAG Model)

Instead of accumulating an array, compose context per-round:

```sql
CREATE VIEW active_context AS
SELECT m.id, m.data as msg_data,
       p.id as part_id, p.data as part_data
FROM message m
LEFT JOIN part p ON p.message_id = m.id
WHERE m.session_id = CURRENT_SESSION()
  AND m.time_created > COMPACTION_BOUNDARY()
  AND (p.id IS NULL OR JSON_EXTRACT(p.data, '$.state.time.compacted') IS NULL)
ORDER BY m.time_created ASC, p.id ASC;
```

The view definition IS the context composition policy. Changes to policy = ALTER VIEW.

## Migration Strategy: Strangler Fig

### Phase 0: Preparation (No Behavior Change)
- Extract `Database` interface from concrete `BunDatabase` implementation
- Make all `Database.use()` callers async-compatible (add await, return Promise)
- Add `StorageBackend` abstraction: `SQLiteBackend` (current) + future `DoltBackend`
- Ship this as a refactor PR — zero functional change, pure preparation

### Phase 1: Dual-Write (Safety Net)
- Add Dolt server as secondary storage
- `Database.use()` writes to both SQLite and Dolt
- Reads still from SQLite (proven path)
- Verify Dolt data matches SQLite via checksums
- This runs in the background — users see no change

### Phase 2: Read from Dolt (The Switch)
- Swap read path to Dolt, keep SQLite writes for rollback
- `filterCompacted` replaced with server-side WHERE clause
- `prune()` actually clears `state.output` (Dolt versioning preserves history)
- Monitor: latency, correctness, memory usage

### Phase 3: Remove SQLite (Cleanup)
- Drop SQLite writes
- Remove `BunDatabase` dependency
- `kilo db` CLI now connects to Dolt server
- Migration tool: one-shot import from kilo.db to Dolt (similar to JsonMigration.run())

### Phase 4: Git DAG Features (New Capabilities)
- Branch-per-tool-call for heavy outputs
- Dolt-native revert (replace revert.ts)
- Context composition via SQL views
- `dolt_diff` for conversation debugging

## Risk Assessment

| Risk | Severity | Mitigation |
|------|----------|------------|
| Dolt server must be running | High | Fallback to embedded SQLite. Or: Dolt embedded mode (no separate process) |
| Async refactor touches ~100 sites | Medium | Mechanical, AST-transformable. Can use codemod |
| MySQL type differences | Low | Drizzle abstracts most differences |
| JSON function syntax differs | Medium | MySQL uses JSON_EXTRACT, SQLite uses json_extract. Drizzle's `sql` template handles this |
| Dolt query latency vs SQLite | Medium | Dolt server mode is fast (<10ms for indexed queries). Benchmark needed |
| BunDatabase sync dependency | High | Some code may rely on synchronous execution semantics. Need audit |
| Dolt storage overhead | Low | Dolt uses content-addressed storage. Similar to git — efficient for structured data |

## Dolt Server Configuration

```yaml
# ~/.config/dolt/server.yaml (or launchctl-managed)
listener:
  host: 127.0.0.1
  port: 3307  # Use a port not in use by other services
  max_connections: 50
performance:
  query_parallelism: 4
databases:
  - name: kilo
    path: ~/.local/share/kilo/dolt/
```

### Storage Layout

```
~/.local/share/kilo/
├── kilo.db              # SQLite (current, deprecated in Phase 3)
└── dolt/                # Dolt database
    ├── .dolt/
    │   ├── noms/        # Content-addressed storage
    │   └── config.json
    └── (no working tables on disk — server mode)
```

## File-by-File Migration Impact

| File | Changes | Effort |
|------|---------|--------|
| `storage/db.ts` | Replace BunDatabase with mysql2, async Client | **High** — core infrastructure |
| `storage/schema.ts` | Re-export from mysqlTable instead of sqliteTable | Low |
| `session/session.sql.ts` | Column type adjustments | Low |
| `session/index.ts` | Add async/await to all Database.use() calls | Medium |
| `session/message-v2.ts` | Async stream(), server-side filterCompacted | **High** — critical path |
| `session/compaction.ts` | Async prune(), actual output clearing | Medium |
| `session/prompt.ts` | Async message loading | Medium |
| `session/processor.ts` | Async part writes | Medium |
| `session/revert.ts` | Replace with Dolt branch operations | Low (simplification) |
| `session/summary.ts` | Async message loading | Low |
| `storage/json-migration.ts` | Add Dolt import path | Low |
| `cli/cmd/db.ts` | Connect to Dolt server instead of sqlite3 | Low |

## Connection to Research Questions

| Question | Answer from Code Mapping |
|----------|------------------------|
| Token overhead (pointers vs inline) | Each tool part's state.output can be 1K-100K tokens. A Dolt ref + summary would be ~50-100 tokens. **100-1000x reduction per tool call** |
| Retrieval latency | Dolt server indexed queries: <10ms. Current SQLite batch-50 pattern: ~5ms per batch but loads ALL data. Net: Dolt faster for filtered queries |
| Summary quality | Compaction already produces LLM summaries. Pointer model adds Dolt refs alongside. No quality degradation — same summaries, just stored differently |
| Semantic search integration | Other Dolt-backed tools could share the same server. Semantic search over tool branches for relevance-based context composition |
| Multi-agent composition | Dolt branches provide native isolation. Merge semantics are well-defined. Current parent_id FK is already the right relationship model |

## Next Steps

- [ ] Prototype StorageBackend interface extraction (Phase 0)
- [ ] Benchmark Dolt server-mode query latency for session-scoped queries
- [ ] Audit all Database.use() call sites for sync-dependency risks
- [ ] Prototype async refactor on a single module (message-v2.ts)
- [ ] Test Drizzle mysql2 driver with Dolt (verify compatibility)
- [ ] Evaluate Dolt embedded mode as fallback (no server process needed)
