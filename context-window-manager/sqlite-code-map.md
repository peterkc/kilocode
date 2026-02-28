# SQLite Code Map — Kilo Code Storage Architecture

Deep mapping of how SQLite is used in Kilo Code's context management system.
Source: `packages/opencode/src/` at commit on `main` branch (2026-02-28).

## Database Infrastructure

### File: `storage/db.ts` — Database Client Factory

```
Database.Path = ~/.local/share/kilo/kilo.db
Database.Client = lazy(() => BunDatabase + Drizzle ORM)
Database.use(cb) = context-local ambient transaction
Database.transaction(cb) = synchronous SQLite transaction
Database.effect(fn) = post-commit side effects
```

PRAGMAs: WAL mode, NORMAL sync, 5s busy timeout, 64MB page cache, FK ON.

Migrations: bundled at build time (`KILO_MIGRATIONS` global) or read from
`migration/` dirs in dev. Uses `drizzle-orm/bun-sqlite/migrator`.

### File: `storage/schema.ts` — Schema Re-exports

Re-exports all table definitions from:
- `session/session.sql.ts` (SessionTable, MessageTable, PartTable, TodoTable, PermissionTable)
- `project/project.sql.ts` (ProjectTable)
- `share/share.sql.ts` (SessionShareTable)
- `control/control.sql.ts` (ControlAccountTable)

### File: `storage/schema.sql.ts` — Shared Column Helper

```typescript
export const Timestamps = {
  time_created: integer().notNull().$default(() => Date.now()),
  time_updated: integer().notNull().$onUpdate(() => Date.now()),
}
```

All timestamps are epoch milliseconds integers.

## Schema: 8 Tables

### Core Conversation Tables (Migration Surface for Dolt)

#### SessionTable
```
id              TEXT PK (descending Identifier)
project_id      TEXT FK -> project CASCADE
parent_id       TEXT nullable (child/subagent sessions)
slug            TEXT
directory       TEXT (working dir at session start)
title           TEXT
version         TEXT
share_url       TEXT nullable
summary_*       INTEGER/JSON (git diff stats for UI)
revert          JSON { messageID, partID?, snapshot?, diff? }
permission      JSON (PermissionNext.Ruleset)
time_created    INTEGER
time_updated    INTEGER
time_compacting INTEGER nullable (epoch ms when compaction started)
time_archived   INTEGER nullable
```
Indexes: session_project_idx, session_parent_idx

#### MessageTable
```
id              TEXT PK (ascending Identifier)
session_id      TEXT FK -> session CASCADE
time_created    INTEGER
time_updated    INTEGER
data            JSON (InfoData — everything except id/sessionID)
```
data contains: role, agent, model, system, tools, format, editorContext (user),
parentID, modelID, providerID, cost, tokens, error, finish, summary (assistant)

Index: message_session_idx

#### PartTable (THE MEMORY PROBLEM)
```
id              TEXT PK (ascending Identifier)
message_id      TEXT FK -> message CASCADE
session_id      TEXT (denormalized for fast session-scoped queries)
time_created    INTEGER
time_updated    INTEGER
data            JSON (PartData — everything except id/sessionID/messageID)
```
data.type: text | tool | reasoning | step-start | step-finish | file |
           patch | snapshot | agent | retry | compaction | subtask

**Critical**: For tool parts, `data.state.output` holds the FULL tool output text.
This is NEVER cleared by prune() — only flagged with `data.state.time.compacted`.

Index: part_message_idx, part_session_idx

### Supporting Tables (Lower Priority for Migration)

#### TodoTable
```
session_id  TEXT FK -> session CASCADE
content     TEXT, status TEXT, priority TEXT, position INTEGER
PK: (session_id, position)
```

#### PermissionTable
```
project_id  TEXT PK FK -> project CASCADE
data        JSON (PermissionNext.Ruleset)
```

#### ProjectTable
```
id TEXT PK, worktree TEXT, vcs TEXT, name TEXT
icon_url TEXT, icon_color TEXT, sandboxes JSON, commands JSON
```

#### SessionShareTable
```
session_id TEXT PK FK -> session CASCADE
id TEXT, secret TEXT, url TEXT
```

#### ControlAccountTable
```
PK: (email, url)
access_token TEXT, refresh_token TEXT, token_expiry INTEGER, active INTEGER
```

## Entity Relationships

```
project ---1:N---> session ---1:N---> message ---1:N---> part
                     |
                     +---1:N---> todo
                     +---1:1---> session_share
project ---1:1---> permission
```

All FK relationships use ON DELETE CASCADE.

## Data Access Patterns

### All SQLite Callers (7 primary + 1 CLI)

| Caller | File | Operations | Notes |
|--------|------|------------|-------|
| Session.create/get/list | session/index.ts | INSERT/SELECT session, message, part | Core CRUD |
| MessageV2.stream() | session/message-v2.ts | SELECT messages DESC, batch SELECT parts | **Pages 50 at a time** |
| Session.updatePart() | session/index.ts | INSERT ON CONFLICT UPDATE part | **Full JSON upsert** |
| SessionCompaction.prune() | session/compaction.ts | SELECT all messages, UPDATE part.data | Sets time.compacted flag |
| SessionCompaction.process() | session/compaction.ts | INSERT summary message + parts | Creates compaction summary |
| SessionRevert.cleanup() | session/revert.ts | DELETE messages after revert point | Only actual deletion |
| SessionSummary.summarize() | session/summary.ts | SELECT all messages for diff stats | UI-only, not LLM-related |
| JsonMigration.run() | storage/json-migration.ts | Bulk INSERT from flat files | One-shot migration |
| kilo db CLI | cli/cmd/db.ts | Raw sqlite3 shell or ad-hoc SELECT | Developer tool |

### Critical Hot Path: Each LLM Round

```
1. MessageV2.stream(sessionID)
   -> SELECT from MessageTable DESC, LIMIT 50, OFFSET N
   -> For each batch: SELECT from PartTable WHERE message_id IN (batch_ids)
   -> Yield { info, parts[] } newest-first
   -> ALL data deserialized from JSON into JS heap objects

2. filterCompacted(stream)
   -> Walks the stream, collects messages until compaction boundary
   -> Returns post-compaction messages only (but stream() already loaded them ALL)

3. toModelMessages(filtered, model)
   -> Builds fresh ModelMessage[] array
   -> For compacted tool parts: substitutes "[Old tool result content cleared]"
   -> For non-compacted: includes full state.output text

4. LLM.stream() -> Vercel AI SDK -> Provider API
```

**Problem**: Step 1 loads ALL parts (including compacted ones) into JS heap.
filterCompacted in Step 2 drops the references, but bmalloc already allocated.
Over many rounds, freed memory fragments the heap.

## Compaction Pipeline Detail

### Trigger: isOverflow()
```
usable = model.limit.input
  ? model.limit.input - reserved
  : model.limit.context - maxOutputTokens(model)

reserved = config.compaction?.reserved ?? min(20_000, maxOutputTokens(model))
maxOutputTokens = min(model.limit.output, 32_000)

overflow when: total_tokens >= usable
```

### Create: SessionCompaction.create()
Adds a CompactionPart to the most recent user message. This is a marker that
tells the next loop iteration to run the compaction process.

### Process: SessionCompaction.process()
1. Gets the "compaction" agent config (model selection)
2. Loads full conversation via toModelMessages()
3. Creates a user message: "What did we do so far?" + structured prompt
4. LLM generates continuation summary
5. Stores as assistant message with `summary: true`

### Prune: SessionCompaction.prune() — Called ONCE at loop exit
1. Load ALL session messages via Session.messages()
2. Walk backwards, skip newest 2 user turns
3. Stop at summary boundary or already-compacted part
4. For tool parts beyond 40K token window: set time.compacted = Date.now()
5. Write back to SQLite via Session.updatePart()
6. **DOES NOT clear state.output** — data persists in DB forever

### FilterCompacted: MessageV2.filterCompacted()
Walks stream (newest-first). Finds completed summary + its parent user message
with compaction part. Returns only messages AFTER that boundary.

## Revert System

### revert() — session/revert.ts
- Stores revert pointer on session: { messageID, partID?, snapshot, diff }
- Calls Snapshot.revert() to undo file changes
- Does NOT delete messages from DB

### cleanup() — Called at prompt() start
- Deletes messages AFTER the revert point
- The only place messages are actually DELETE'd from SQLite
- If partID specified: deletes parts from that point in the target message

### unrevert()
- Restores snapshot, clears revert pointer
- No DB message changes

## The GH#6442 Memory Problem

### Root Cause Chain

1. `state.output` on tool parts holds full tool output (file contents, bash stdout, etc.)
2. `prune()` only sets `time.compacted` flag — output stays in DB
3. `MessageV2.stream()` loads ALL parts (including compacted) into JS heap
4. `filterCompacted()` drops old messages but allocation already happened
5. `toModelMessages()` builds a NEW array each round
6. Over many rounds: overlapping allocation waves fragment bmalloc regions
7. bmalloc's non-moving allocator can't compact freed memory
8. Result: 8.1 GB footprint, 85 MB live, 80:1 waste ratio

### Where Each Fix Would Touch

| Fix | Files | Impact |
|-----|-------|--------|
| Clear state.output in prune() | compaction.ts:93 | Reduces DB size, but doesn't fix heap fragmentation |
| Lazy-load parts (don't deserialize until needed) | message-v2.ts:stream() | Reduces per-round heap pressure |
| Server-side filtering (Dolt) | db.ts, message-v2.ts | Eliminates in-process deserialization entirely |
| Branch-per-tool-call (Dolt) | compaction.ts, prompt.ts | Structural fix: heavy data never on trunk |
