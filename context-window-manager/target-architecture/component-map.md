# Component Map: Existing → Target

Mapping every Kilo Code module affected by the storage architecture change.

## Complete Database Touch Surface

**52 `Database.use/transaction` calls across 11 files.**

| Module | File | Calls | Purpose |
|--------|------|-------|---------|
| **session** | `session/index.ts` | 18 | Session CRUD, message/part persistence, archive |
| **project** | `project/project.ts` | 14 | Project CRUD, worktree association, sandboxes |
| **message** | `session/message-v2.ts` | 4 | Stream messages, create message, batch parts |
| **share** | `share/share-next.ts` | 3 | Session sharing (URL, secret) |
| **control** | `control/index.ts` | 3 | OAuth account storage |
| **import** | `cli/cmd/import.ts` | 3 | Import sessions from file |
| **todo** | `session/todo.ts` | 2 | Todo list persistence |
| **revert** | `session/revert.ts` | 2 | DELETE messages/parts on cleanup |
| **permission** | `permission/next.ts` | 1 | Permission ruleset storage |
| **worktree** | `worktree/index.ts` | 1 | Project lookup for worktree init |
| **stats** | `cli/cmd/stats.ts` | 1 | Read-only session stats |

Plus supporting infrastructure:
- `storage/db.ts` — Database singleton, Client, use(), transaction(), effect()
- `storage/schema.ts` — Re-exports all table definitions
- `storage/schema.sql.ts` — Shared Timestamps column helper
- `storage/storage.ts` — Legacy JSON file storage (pre-SQLite)
- `storage/json-migration.ts` — One-shot JSON→SQLite migrator

## Component Transformation Map

### Layer 1: Storage Infrastructure

```
CURRENT                              TARGET
───────                              ──────
storage/db.ts                    →   storage/port.ts (interfaces)
  Database.Client (lazy singleton)   storage/wire.ts (factory)
  Database.use()                     storage/adapters/sqlite.ts
  Database.transaction()             storage/adapters/dolt.ts
  Database.effect()                  storage/adapters/postgres.ts

storage/schema.ts                →   storage/schema/ (per-backend)
  Re-exports all tables              schema/common.ts (shared types)
                                     schema/sqlite.ts (sqliteTable defs)
                                     schema/dolt.ts (mysqlTable defs)
                                     schema/views.ts (Silver view DDL)

storage/schema.sql.ts            →   storage/schema/timestamps.ts
  Timestamps helper                  (unchanged, backend-agnostic)

storage/storage.ts               →   DEPRECATED (remove after migration)
  Legacy JSON file storage           All data in StoragePort

storage/json-migration.ts        →   storage/migration/
  JSON→SQLite one-shot               from-json.ts (existing)
                                     from-sqlite.ts (SQLite→Dolt one-shot)
                                     dolt-migrations/ (schema versioning)
```

### Layer 2: Session Management

```
CURRENT                              TARGET
───────                              ──────
session/index.ts (18 DB calls)   →   session/index.ts (uses StoragePort)
  Session.create()                    storage.createSession()
  Session.get()                       storage.getSession()
  Session.list()                      storage.listSessions()
  Session.updateMessage()             storage.createMessage() / updateMessage()
  Session.updatePart()                storage.updatePart()
  Session.delete()                    storage.deleteSession()
  Session.archive()                   storage.updateSession({archived: true})
  Session.messages()                  storage.streamMessages()
  + Bus.publish side effects          StoragePort.onWrite hook → Bus.publish

session/message-v2.ts            →   session/message-v2.ts (partial refactor)
  stream() — pages from DB           storage.streamMessages() (delegates)
  filterCompacted() — walks stream    REPLACED by Silver view v_active_context
  toModelMessages() — builds array    Unchanged (consumes view results)
  fromRow/toRow — schema mapping      Moved to adapter layer

session/compaction.ts            →   session/compaction.ts + Gold layer
  isOverflow()                        context.update lifecycle event (zones)
  create()                            compact.pre lifecycle event
  process()                           LLM summary → Gold session_summaries table
  prune()                             Dolt: actual DELETE + branch prune
                                      SQLite: existing flag behavior (fallback)
                                      compact.post lifecycle event

session/revert.ts                →   session/revert.ts (simplified)
  revert() — snapshot + pointer       Dolt: storage.commit() + storage.asOf()
  unrevert() — restore snapshot       Dolt: storage.checkout('HEAD')
  cleanup() — DELETE messages         Dolt: storage.checkout(commitBefore)
                                      SQLite: unchanged (DELETE)

session/prompt.ts                →   session/prompt.ts (context composition)
  loop()                              Mostly unchanged
  filterCompacted() call              Replaced by storage.streamMessages()
                                      which returns only active context
  Tool execution hooks                + tool.pre / tool.post lifecycle events
  createUserMessage()                 + turn.start lifecycle event
  End of loop                         + turn.end lifecycle event
                                      + context.update lifecycle event

session/llm.ts                   →   session/llm.ts (minimal changes)
  LLM.stream()                        Unchanged (consumes ModelMessage[])
  Plugin.trigger chat.system           + context budget section injection
  Plugin.trigger chat.params           Unchanged

session/processor.ts             →   session/processor.ts (+ lifecycle events)
  Handle stream events                 Unchanged
  finish-step handler                  + context.update lifecycle event
  tool-result handler                  + tool.post lifecycle event (unified)
  error handler                        + tool.post lifecycle event (error path)

session/summary.ts               →   session/summary.ts (unchanged)
  Git diff stats for UI               Unchanged (not storage-related)

session/instruction.ts           →   session/instruction.ts (unchanged)
  AGENTS.md / CLAUDE.md loading       Unchanged

session/todo.ts (2 DB calls)     →   session/todo.ts (uses StoragePort)
  Todo CRUD                           storage.todo.* methods
```

### Layer 3: Tool System

```
CURRENT                              TARGET
───────                              ──────
tool/tool.ts                     →   tool/tool.ts (+ progressive disclosure)
  Universal truncation wrapper         Three-tier routing:
  Truncate.output() at 50KB            ≤1KB: inline (Tier 1)
                                        1-50KB: summary + ref (Tier 2)
                                        >50KB: ref only (Tier 3)

tool/truncation.ts               →   tool/truncation.ts → tool/disclosure.ts
  MAX_LINES = 2000                    INLINE_THRESHOLD = 1024 (1KB)
  MAX_BYTES = 50KB                    SUMMARY_THRESHOLD = 50KB
  Truncate.output()                   Disclosure.process()
  Temp file storage                   StoragePort.storeTool() (Dolt/Postgres)
                                      Temp file fallback (SQLite)

tool/read.ts                     →   tool/read.ts (+ smart summarizer)
  Returns full content                 Tier 1: small files inline
  Own 2000-line truncation             Tier 2: file structure summary + ref
                                       Language-aware: imports, exports, sections

tool/bash.ts                     →   tool/bash.ts (+ output classifier)
  Returns raw stdout/stderr            Tier 1: short output inline
  No truncation (gets wrapper)         Tier 2: classified summary + ref
                                       Type detection: test/build/git/generic

tool/grep.ts                     →   tool/grep.ts (+ result digest)
  Returns match lines                  Tier 1: ≤5 matches inline
  100-match limit                      Tier 2: distribution + top matches + ref

tool/glob.ts                     →   tool/glob.ts (minimal change)
  100-file limit                       Tier 1 usually (file paths are small)

tool/webfetch.ts                 →   tool/webfetch.ts (+ page summarizer)
  Returns full page markdown           Tier 2/3: title, headings, word count + ref

tool/codesearch.ts               →   tool/codesearch.ts (minimal change)
  Token-budget from API                Already has progressive behavior

NEW: tool/retrieve.ts            ←   NEW tool for on-demand detail
                                      retrieve --ref <id> [--offset N] [--grep pattern]
```

### Layer 4: Plugin System

```
CURRENT                              TARGET
───────                              ──────
plugin/index.ts                  →   plugin/index.ts (+ lifecycle dispatch)
  Hooks interface (13 hooks)          Hooks interface (13 + 15 = 28 hooks)
  Plugin.trigger() — sequential       Plugin.trigger() — transforms (unchanged)
  Bus.subscribeAll() for events       Plugin.emit() — lifecycle (NEW, parallel)

  EXISTING TRANSFORM HOOKS:           UNCHANGED:
  chat.message                        chat.message
  chat.params                         chat.params
  chat.headers                        chat.headers
  tool.execute.before                 tool.execute.before
  tool.execute.after                  tool.execute.after
  tool.definition                     tool.definition
  permission.ask                      permission.ask
  shell.env                           shell.env
  command.execute.before              command.execute.before
  experimental.chat.system.transform  experimental.chat.system.transform
  experimental.chat.messages.transform experimental.chat.messages.transform
  experimental.session.compacting     experimental.session.compacting
  experimental.text.complete          experimental.text.complete

                                      NEW LIFECYCLE EVENTS (Plugin.emit):
                                      session.start
                                      session.end
                                      session.stop
                                      turn.start
                                      turn.end
                                      tool.pre
                                      tool.post (unified success + error)
                                      agent.start
                                      agent.stop
                                      compact.pre
                                      compact.post
                                      context.update
                                      storage.write
                                      storage.read
                                      model.switch.before (transform)

plugin/codex.ts                  →   plugin/codex.ts (unchanged)
plugin/copilot.ts                →   plugin/copilot.ts (unchanged)
```

### Layer 5: Project & Supporting Modules

```
CURRENT                              TARGET
───────                              ──────
project/project.ts (14 DB calls) →   project/project.ts (uses StoragePort)
  Project CRUD                        storage.project.* methods
  Worktree association                Unchanged logic, different access

project/project.sql.ts           →   Moved to storage/schema/
  ProjectTable definition             Backend-specific table definitions

share/share-next.ts (3 DB calls) →   share/share-next.ts (uses StoragePort)
  Share CRUD                          storage.share.* methods

share/share.sql.ts               →   Moved to storage/schema/
  SessionShareTable definition

control/index.ts (3 DB calls)   →   control/index.ts (uses StoragePort)
  OAuth accounts                      storage.control.* methods

control/control.sql.ts           →   Moved to storage/schema/
  ControlAccountTable definition

permission/next.ts (1 DB call)   →   permission/next.ts (uses StoragePort)
  Permission ruleset                  storage.permission.* methods

worktree/index.ts (1 DB call)    →   worktree/index.ts (uses StoragePort)
  Project lookup                      storage.getProject()

cli/cmd/import.ts (3 DB calls)   →   cli/cmd/import.ts (uses StoragePort)
  Session import                      storage.importSession()

cli/cmd/stats.ts (1 DB call)     →   cli/cmd/stats.ts (uses StoragePort)
  Read-only stats                     storage.listSessions() + compute

cli/cmd/db.ts                    →   cli/cmd/db.ts (backend-aware)
  sqlite3 shell                       Dolt: mysql shell / dolt sql
                                      Postgres: psql
                                      SQLite: sqlite3 (unchanged)
```

### Layer 6: New Components (Don't Exist Today)

```
NEW COMPONENTS
──────────────
storage/port.ts                  ←   Interface definitions
  StoragePort (base)                  Required for all backends
  VersionedStorage                    Optional: commit, asOf, diff, log
  BranchingStorage                    Optional: branch, checkout, merge, gc
  SearchableStorage                   Optional: vectorSearch, textSearch
  HookableStorage                     Optional: onWrite, onRead hooks

storage/wire.ts                  ←   Composition root
  StorageFactory.create(config)       Backend selection + initialization

storage/adapters/sqlite.ts       ←   Wraps current db.ts behavior
storage/adapters/dolt.ts         ←   mysql2 + Dolt stored procedures
storage/adapters/postgres.ts     ←   pg + Drizzle postgres driver

storage/schema/views.ts          ←   Silver view definitions
  v_active_context                    Replaces filterCompacted()
  v_tool_calls                        Matched tool invocations
  v_session_timeline                  Event-level view

storage/tables/tool_outputs.ts   ←   Progressive disclosure storage
  tool_outputs table                  Full output for Tier 2/3 tools

storage/tables/session_summaries.ts ← Gold layer
  session_summaries table             Compaction recovery

tool/disclosure.ts               ←   Three-tier output routing
  Disclosure.process()                Replaces Truncate.output()

tool/summarizer/                 ←   Per-type summarization
  code.ts                            Language-aware file summarizer
  bash.ts                            Test/build/git output classifier
  search.ts                           Grep/glob result digest
  web.ts                             Web page summarizer

tool/retrieve.ts                 ←   On-demand detail retrieval
  retrieve --ref <id>                 Query Dolt for full output
```

## Modules NOT Affected

These modules have zero `Database.use()` calls and no storage interaction:

| Module | Reason Unaffected |
|--------|-------------------|
| `agent/` | Reads agent definitions from config, not DB |
| `auth/` | Auth flow handled by plugins (Codex, Copilot) |
| `bus/` | Pure event system, no persistence |
| `bun/` | Runtime utilities, plugin installation |
| `cli/` (most) | UI layer, uses session/project APIs |
| `command/` | Command registry, no DB |
| `commit-message/` | Git commit generation, no DB |
| `config/` | File-based config, not DB |
| `env/` | Environment detection |
| `file/` | File system operations, ripgrep |
| `flag/` | Feature flags, no DB |
| `format/` | Output formatting |
| `global/` | Path resolution |
| `id/` | ID generation |
| `ide/` | IDE integration |
| `installation/` | Version checking |
| `kilocode/` | Kilocode-specific extensions |
| `kilo-sessions/` | Kilo cloud session sync (uses HTTP API, not local DB) |
| `lsp/` | Language server protocol |
| `mcp/` | MCP client/server |
| `patch/` | Unified diff application |
| `provider/` | LLM provider management |
| `pty/` | Pseudo-terminal |
| `question/` | User question dialog |
| `scheduler/` | Cron-like scheduling (temp file cleanup) |
| `server/` | Hono HTTP server |
| `shell/` | Shell execution |
| `skill/` | Skill discovery and loading |
| `snapshot/` | Git snapshot (uses git, not DB) |
| `util/` | General utilities |

## Impact Summary

| Category | Files Changed | New Files | Effort |
|----------|--------------|-----------|--------|
| **Storage infrastructure** | 4 modified | 8 new | High |
| **Session management** | 7 modified | 0 new | High |
| **Tool system** | 8 modified | 5 new | Medium |
| **Plugin system** | 1 modified | 0 new | Medium |
| **Project & supporting** | 7 modified | 0 new | Low (mechanical) |
| **Schema definitions** | 4 moved | 3 new | Low |
| **CLI** | 3 modified | 0 new | Low |
| **Total** | **34 modified** | **16 new** | |

**50 files total** — of which 34 are modifications (mostly mechanical `Database.use()` → `storage.*` swaps) and 16 are new infrastructure.

## Dependency Graph

```
Phase 0: storage/port.ts + storage/wire.ts + storage/adapters/sqlite.ts
    ↓
Phase 1: session/index.ts + session/message-v2.ts + project/project.ts
         (swap Database.use → StoragePort — async refactor)
    ↓
Phase 2: tool/disclosure.ts + tool/summarizer/* + tool/retrieve.ts
         (progressive disclosure — independent of backend)
    ↓
Phase 3: storage/adapters/dolt.ts + storage/schema/views.ts
         (Dolt backend — enables branching, versioning, server-side filter)
    ↓
Phase 4: plugin/index.ts (Plugin.emit + 15 lifecycle events)
         storage/tables/session_summaries.ts (Gold layer)
    ↓
Phase 5: compaction.ts + prompt.ts (context.update, smart compaction)
         revert.ts → Dolt versioning
```
