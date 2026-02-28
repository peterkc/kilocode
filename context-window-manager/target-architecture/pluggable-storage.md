# Target Architecture: Pluggable Storage with Medallion Data Lifecycle

## Design Principles

Three sources inform this architecture:

| Source | Pattern Borrowed | Application |
|--------|-----------------|-------------|
| **Hexagonal Architecture** | Ports & Adapters, optional interface probing, composition root | `StoragePort` base + optional capabilities (`Versioned`, `Branching`, `Searchable`) |
| **Medallion Architecture** | Bronze → Silver → Gold data lifecycle | Messages (Bronze) → Context views (Silver) → Compaction summaries (Gold) |
| **Kilo Current** (Hooks) | Plugin system with 13 hook points | Extended with storage lifecycle hooks for observability and interception |

### Core Invariant

**The application layer never imports adapters.** All dependencies point inward:

```
App → Ports ← Adapters
         ↑
    Composition Root (wire.ts)
```

This is the hexagonal architecture pattern. It means swapping SQLite for Dolt changes exactly one
file: the composition root.

---

## 1. Storage Port Interfaces

Borrowing a tiered interface model from hexagonal architecture. The base port is required; everything else is
optional and discovered at runtime via TypeScript type guards.

### Base Port (Required — All Backends)

```typescript
// storage/port.ts

export interface StoragePort {
  // Session CRUD
  createSession(session: Session.Info): Promise<void>
  getSession(id: string): Promise<Session.Info>
  listSessions(projectID: string, opts?: ListOpts): Promise<Session.Info[]>
  updateSession(id: string, patch: Partial<Session.Info>): Promise<void>
  deleteSession(id: string): Promise<void>

  // Message CRUD
  createMessage(msg: MessageV2.Info): Promise<void>
  streamMessages(sessionID: string): AsyncGenerator<MessageV2.WithParts>
  updateMessage(id: string, patch: Partial<MessageV2.Info>): Promise<void>
  deleteMessages(filter: MessageFilter): Promise<number>

  // Part CRUD
  createPart(part: MessageV2.Part): Promise<void>
  updatePart(part: MessageV2.Part): Promise<void>
  getPartsForMessages(messageIDs: string[]): Promise<Map<string, MessageV2.Part[]>>

  // Transaction
  transaction<T>(fn: (tx: StorageTransaction) => Promise<T>): Promise<T>

  // Lifecycle
  initialize(): Promise<void>
  close(): Promise<void>
  migrate(): Promise<void>
}
```

This maps 1:1 to Kilo's current `Database.use()` call sites. Every existing caller
uses one of these operations.

### Versioned Storage (Optional — Dolt, Postgres+temporal)

```typescript
// storage/port.ts

export interface VersionedStorage extends StoragePort {
  // Commit the current state
  commit(message: string): Promise<string>  // returns commit hash

  // Time-travel queries
  asOf<T>(timestamp: Date | string, fn: (port: StoragePort) => Promise<T>): Promise<T>

  // Diff between two points
  diff(from: string, to: string, table: string): Promise<DiffRow[]>

  // History log
  log(opts?: { limit?: number; table?: string }): Promise<CommitInfo[]>
}
```

This replaces hand-rolled `revert.ts`. Instead of tracking snapshot pointers:
- `revert()` → `asOf(commitBeforeMessage, ...)`
- `unrevert()` → `asOf('HEAD', ...)`
- `cleanup()` → just read from the correct commit

### Branching Storage (Optional — Dolt Only)

```typescript
// storage/port.ts

export interface BranchingStorage extends VersionedStorage {
  // Branch management
  createBranch(name: string, from?: string): Promise<void>
  deleteBranch(name: string): Promise<void>
  checkout(ref: string): Promise<void>
  merge(source: string, opts?: MergeOpts): Promise<MergeResult>
  listBranches(): Promise<BranchInfo[]>

  // Garbage collection
  gc(): Promise<GCStats>
}
```

This enables the Git DAG model from the seed research:
- Each subagent gets its own branch
- Tool outputs go to `tool/<callID>` branches
- Compaction = `deleteBranch()` + `gc()`
- Context trunk stays small (pointers to branches)

### Searchable Storage (Optional — Dolt + Semantic Search, Postgres+pgvector)

```typescript
// storage/port.ts

export interface SearchableStorage extends StoragePort {
  // Vector similarity search
  vectorSearch(embedding: number[], opts: VectorSearchOpts): Promise<SearchResult[]>

  // Full-text search
  textSearch(query: string, opts?: TextSearchOpts): Promise<SearchResult[]>
}
```

This is the semantic search integration point. When Dolt backend is active and a semantic search provider is installed,
search over conversation history becomes native.

### Hookable Storage (Optional — All Backends, Plugin Bridge)

```typescript
// storage/port.ts

export interface HookableStorage extends StoragePort {
  // Lifecycle hooks (bridged to Plugin.trigger)
  onBeforeWrite(hook: StorageWriteHook): void
  onAfterWrite(hook: StorageWriteHook): void
  onBeforeRead(hook: StorageReadHook): void
  onAfterRead(hook: StorageReadHook): void
}
```

This extends Kilo's current 13-hook plugin system with storage lifecycle events.
A plugin can now observe (or modify) every DB write — enabling:
- Shadow replication to external systems
- Audit logging
- Real-time sync to team Dolt servers

---

## 2. Optional Interface Probing (Hexagonal Architecture Pattern)

The key pattern from hexagonal architecture: callers check for optional capabilities at runtime.

```typescript
// session/compaction.ts — using optional interface probing

async function prune(input: { sessionID: string }) {
  const storage = StorageFactory.get()

  // Base behavior: mark parts as compacted
  const parts = await findPrunableParts(storage, input.sessionID)
  for (const part of parts) {
    part.state.time.compacted = Date.now()

    // If storage supports branching: actually remove the output data
    // (Dolt versioning preserves history via commits)
    if (isBranching(storage)) {
      part.state.output = null  // safe: asOf() recovers if needed
    }

    await storage.updatePart(part)
  }

  // If storage supports branching: clean up tool branches
  if (isBranching(storage)) {
    const toolBranches = (await storage.listBranches())
      .filter(b => b.name.startsWith('tool/') && b.age > PRUNE_AGE)
    for (const branch of toolBranches) {
      await storage.deleteBranch(branch.name)
    }
    await storage.gc()
  }

  // If storage supports versioning: commit the prune
  if (isVersioned(storage)) {
    await storage.commit(`prune: cleared ${parts.length} compacted outputs`)
  }
}

// Type guards (Go-style interface assertion pattern)
function isVersioned(s: StoragePort): s is VersionedStorage {
  return 'commit' in s && 'asOf' in s
}
function isBranching(s: StoragePort): s is BranchingStorage {
  return isVersioned(s) && 'createBranch' in s
}
function isSearchable(s: StoragePort): s is SearchableStorage {
  return 'vectorSearch' in s
}
```

**Why this matters**: SQLite users get the same behavior they have today (base port only).
Dolt users get structural improvements (true pruning, branch isolation, versioned history).
No feature flags needed — capabilities are auto-detected from the adapter.

---

## 3. Medallion Data Lifecycle

Borrowing from the medallion data lifecycle pattern. Three layers with clear boundaries:

### Bronze: Raw Capture (Message + Part Tables)

```
session → message → part (with full state.output)
```

Every tool call, every text segment, every reasoning block is stored verbatim.
This is what Kilo does today. The schema stays the same.

**New**: Storage hooks fire on every write, enabling:
- Plugin-based mirroring to external systems
- Real-time event streaming (via a hook-based event dispatcher)
- Audit trail in Dolt's commit log

### Silver: Context Views (SQL Views or Computed Queries)

```sql
-- v_active_context: What the LLM sees this round
-- Replaces filterCompacted() + toModelMessages() logic
CREATE VIEW v_active_context AS
SELECT m.id, m.data as msg,
       p.id as part_id, p.data as part
FROM message m
LEFT JOIN part p ON p.message_id = m.id
WHERE m.session_id = CURRENT_SESSION()
  AND m.time_created > (
    SELECT COALESCE(MAX(m2.time_created), 0)
    FROM message m2
    JOIN part p2 ON p2.message_id = m2.id
    WHERE m2.session_id = CURRENT_SESSION()
      AND JSON_EXTRACT(p2.data, '$.type') = 'compaction'
      AND EXISTS (
        SELECT 1 FROM message m3
        WHERE m3.session_id = CURRENT_SESSION()
          AND JSON_EXTRACT(m3.data, '$.summary') = true
          AND JSON_EXTRACT(m3.data, '$.parentID') = m2.id
      )
  )
ORDER BY m.time_created ASC, p.id ASC;

-- v_tool_calls: Matched tool invocations with duration
CREATE VIEW v_tool_calls AS
SELECT p.id, p.session_id,
       JSON_EXTRACT(p.data, '$.tool') as tool_name,
       JSON_EXTRACT(p.data, '$.state.status') as status,
       JSON_EXTRACT(p.data, '$.state.time.start') as started_at,
       JSON_EXTRACT(p.data, '$.state.time.end') as ended_at,
       CASE WHEN JSON_EXTRACT(p.data, '$.state.time.compacted') IS NOT NULL
            THEN '[compacted]'
            ELSE JSON_EXTRACT(p.data, '$.state.output')
       END as output
FROM part p
WHERE JSON_EXTRACT(p.data, '$.type') = 'tool';

-- v_session_timeline: Event-level view
CREATE VIEW v_session_timeline AS
SELECT m.id as message_id, m.session_id,
       JSON_EXTRACT(m.data, '$.role') as role,
       p.id as part_id,
       JSON_EXTRACT(p.data, '$.type') as part_type,
       p.time_created
FROM message m
JOIN part p ON p.message_id = m.id
ORDER BY m.time_created ASC, p.id ASC;
```

**For SQLite**: These views work as-is (SQLite supports `json_extract()`).
**For Dolt**: Same views, plus `dolt_diff` for change tracking.
**For Postgres**: Same views with `jsonb_extract_path_text()`.

The Silver layer replaces `filterCompacted()` as imperative code with declarative SQL.
This is a major simplification — the context composition policy becomes a view definition.

### Gold: Persisted Summaries (Compaction Recovery)

```sql
CREATE TABLE session_summaries (
    session_id   TEXT PRIMARY KEY,
    structured   JSON NOT NULL,        -- tool counts, file stats, token metrics
    context_md   TEXT NOT NULL,         -- compact markdown for injection (~500 tokens)
    embedding    VECTOR(768),          -- semantic search (Dolt/Postgres only)
    computed_at  DATETIME NOT NULL
);
```

Gold is persisted at compaction time (via a pre-compaction lifecycle hook).
If the session crashes or compacts, Gold provides recovery context.

**Current Kilo**: The compaction summary is stored as a regular assistant message
with `summary: true`. This is fragile — it's mixed in with regular messages.

**Target**: Gold lives in a dedicated table. The compaction summary message still
exists for LLM context, but the Gold table provides a structured, queryable,
cross-session knowledge base.

---

## 4. Extended Hook System

Kilo has 13 hooks today. The target adds 4 storage hooks:

### New Storage Hooks

| Hook | Type | When | What Plugin Gets |
|------|------|------|-----------------|
| `storage.session.write` | Modify-capable | Before session write | Full session object |
| `storage.session.read` | Modify-capable | After session load | Full session + parts |
| `storage.part.write` | Observe + modify | Before part upsert | Part with state.output |
| `storage.compaction.complete` | Observe-only | After prune + commit | Compaction stats |

These bridge the gap between Kilo's LLM-focused plugin system and the storage layer.
A plugin author can now:

```typescript
// Example: Mirror to team Dolt server
export default async function(input: PluginInput): Promise<Hooks> {
  return {
    "storage.part.write": async ({ part }, output) => {
      if (part.type === "tool" && part.state.status === "completed") {
        await teamDolt.insert("shared_tool_results", {
          sessionID: part.sessionID,
          tool: part.tool,
          output: part.state.output,
        })
      }
    },
    "storage.compaction.complete": async ({ stats }) => {
      await teamDolt.commit(`session ${stats.sessionID}: compacted ${stats.prunedParts} parts`)
    },
  }
}
```

### Hook Execution Points in the Data Lifecycle

```
User sends message
  → storage.session.write        ← NEW: plugins can observe/modify
  → Bronze INSERT (message + parts)
  → [LLM processes]
  → storage.part.write (×N)      ← NEW: each tool result
  → Bronze UPDATE (parts with outputs)
  → [Session continues...]
  → isOverflow() triggers compaction
  → Silver views compute active context
  → Gold: session_summaries persist
  → storage.compaction.complete  ← NEW: plugins notified
  → prune() clears compacted outputs
```

---

## 5. Composition Root (wire.ts)

Following the composition root pattern, one file handles all adapter selection:

```typescript
// storage/wire.ts

import type { StoragePort } from "./port"

export namespace StorageFactory {
  let instance: StoragePort | undefined

  export async function create(config: StorageConfig): Promise<StoragePort> {
    switch (config.backend) {
      case "sqlite":
        const { SQLiteAdapter } = await import("./adapters/sqlite")
        instance = new SQLiteAdapter(config.sqlite)
        break
      case "dolt":
        const { DoltAdapter } = await import("./adapters/dolt")
        instance = new DoltAdapter(config.dolt)
        break
      case "postgres":
        const { PostgresAdapter } = await import("./adapters/postgres")
        instance = new PostgresAdapter(config.postgres)
        break
      default:
        throw new Error(`Unknown storage backend: ${config.backend}`)
    }

    await instance.initialize()
    await instance.migrate()
    return instance
  }

  export function get(): StoragePort {
    if (!instance) throw new Error("Storage not initialized")
    return instance
  }
}
```

### Configuration

```json
// opencode.json / kilo.json
{
  "storage": {
    "backend": "dolt",
    "dolt": {
      "host": "127.0.0.1",
      "port": 3307,
      "database": "kilo",
      "autoCommit": true,
      "branchPerSession": true
    }
  }
}
```

Or environment variable: `KILO_STORAGE_BACKEND=dolt`

Default remains `sqlite` for zero-config experience. Dolt is opt-in.

---

## 6. Adapter Implementations

### SQLiteAdapter (Current Behavior, Wrapped)

```typescript
// storage/adapters/sqlite.ts

export class SQLiteAdapter implements StoragePort, HookableStorage {
  private db: SQLiteBunDatabase<Schema>

  async initialize() {
    // Exactly what db.ts does today
    const sqlite = new BunDatabase(this.config.path, { create: true })
    sqlite.run("PRAGMA journal_mode = WAL")
    // ... other PRAGMAs
    this.db = drizzle({ client: sqlite, schema })
  }

  async streamMessages(sessionID: string) {
    // Exactly what MessageV2.stream() does today
    // Paged SELECT, batch part loading, yield WithParts
  }

  async transaction<T>(fn: (tx) => Promise<T>): Promise<T> {
    // Wrap BunDatabase's synchronous tx in a Promise
    return new Promise((resolve) => {
      this.db.transaction((tx) => {
        resolve(fn(tx))
      })
    })
  }

  // HookableStorage: delegate to Plugin.trigger
  onBeforeWrite(hook) { this.writeHooks.push(hook) }
  onAfterWrite(hook) { this.afterWriteHooks.push(hook) }
}
```

### DoltAdapter (Full Capabilities)

```typescript
// storage/adapters/dolt.ts

export class DoltAdapter implements StoragePort, VersionedStorage,
                                     BranchingStorage, SearchableStorage,
                                     HookableStorage {
  private pool: mysql2.Pool

  async initialize() {
    this.pool = mysql2.createPool({
      host: this.config.host,
      port: this.config.port,
      database: this.config.database,
      waitForConnections: true,
      connectionLimit: 10,
    })
  }

  async streamMessages(sessionID: string) {
    // SERVER-SIDE filtering — only non-compacted parts cross the wire
    const rows = await this.pool.query(`
      SELECT m.id, m.data as msg_data, p.id as part_id, p.data as part_data
      FROM message m
      LEFT JOIN part p ON p.message_id = m.id
      WHERE m.session_id = ?
        AND JSON_EXTRACT(p.data, '$.state.time.compacted') IS NULL
      ORDER BY m.time_created ASC, p.id ASC
    `, [sessionID])
    // Yield WithParts — only what the LLM actually needs
  }

  // VersionedStorage
  async commit(message: string): Promise<string> {
    await this.pool.query("CALL DOLT_ADD('-A')")
    const [result] = await this.pool.query("CALL DOLT_COMMIT('-m', ?)", [message])
    return result[0].hash
  }

  async asOf<T>(ref: string, fn: (port) => Promise<T>): Promise<T> {
    // Execute fn against a snapshot of the DB at the given commit
    const snapshotPort = new DoltSnapshotAdapter(this.pool, ref)
    return fn(snapshotPort)
  }

  // BranchingStorage
  async createBranch(name: string) {
    await this.pool.query("CALL DOLT_BRANCH(?)", [name])
  }

  async gc(): Promise<GCStats> {
    await this.pool.query("CALL DOLT_GC()")
    // Return stats
  }

  // SearchableStorage (with semantic search provider)
  async vectorSearch(embedding: number[], opts: VectorSearchOpts) {
    return this.pool.query(`
      SELECT *, VEC_DISTANCE(embedding, STRING_TO_VECTOR(?)) as distance
      FROM session_summaries
      WHERE distance < ?
      ORDER BY distance ASC
      LIMIT ?
    `, [JSON.stringify(embedding), opts.threshold, opts.limit])
  }
}
```

### PostgresAdapter (Team/Cloud)

```typescript
// storage/adapters/postgres.ts

export class PostgresAdapter implements StoragePort, SearchableStorage,
                                         HookableStorage {
  // Uses pg + Drizzle postgres driver
  // No versioning or branching — but pgvector for search
  // Good for team deployments where Dolt isn't available
}
```

---

## 7. Migration Path: Current → Target

### Phase 0: Interface Extraction (No Behavior Change)

**Goal**: Define `StoragePort` and wrap current SQLite code in `SQLiteAdapter`.

```
BEFORE:  Session → Database.use() → BunDatabase
AFTER:   Session → StoragePort → SQLiteAdapter → BunDatabase
```

**Files changed**:
- NEW: `storage/port.ts` (interfaces)
- NEW: `storage/adapters/sqlite.ts` (wrap current db.ts)
- NEW: `storage/wire.ts` (factory, defaults to sqlite)
- MODIFY: `session/index.ts` — use `StorageFactory.get()` instead of `Database.use()`
- MODIFY: `session/message-v2.ts` — same
- MODIFY: All other callers — same

**Key constraint**: This phase is a pure refactor. Tests must pass unchanged.
The `SQLiteAdapter` wraps `Database.use()` exactly — same sync behavior.

**PR strategy**: Deliver as a small, mechanical, reviewable refactor.
Demonstrates architectural thinking without functional change.

### Phase 1: Async Foundation

**Goal**: Make `StoragePort` async. Migrate `SQLiteAdapter` to async wrappers.

The base port is async from the start (Dolt requires it). But `SQLiteAdapter`
wraps BunDatabase's synchronous calls in Promises for compatibility.

This means all call sites become `await storage.doThing()` — but the actual
SQLite operations are still synchronous under the hood.

### Phase 2: Dolt Adapter (New Backend)

**Goal**: Implement `DoltAdapter` with full capabilities.

- `mysql2` connection pool
- Server-side filtering in `streamMessages()`
- `commit()`, `asOf()`, `diff()` via Dolt stored procedures
- `createBranch()`, `merge()`, `gc()` for Git DAG model
- Silver views created during `migrate()`

**Dual-write mode**: Both SQLite and Dolt receive writes. Reads from SQLite.
Checksum verification between the two.

### Phase 3: Storage Hooks + Plugin Bridge

**Goal**: Add 4 storage hooks to the plugin system.

- `storage.session.write` — before session persistence
- `storage.session.read` — after session load
- `storage.part.write` — before part upsert
- `storage.compaction.complete` — after compaction

These fire through Kilo's existing `Plugin.trigger()` mechanism.

### Phase 4: Silver Views + Gold Tables

**Goal**: Medallion data lifecycle.

- Create SQL views (`v_active_context`, `v_tool_calls`, `v_session_timeline`)
- Create `session_summaries` Gold table
- Refactor `filterCompacted()` to use `v_active_context` view (Dolt/Postgres)
  or keep imperative logic (SQLite fallback)
- Compaction persists Gold summaries

### Phase 5: Git DAG Model (Dolt-Only Features)

**Goal**: Branch-per-tool-call, context as SQL composition.

- Heavy tool outputs go to `tool/<callID>` branches
- Trunk only holds pointers + summaries
- Compaction = branch pruning + gc
- Context composition via parameterized SQL views
- `revert.ts` replaced by `asOf()` / `checkout()`

---

## 8. Configuration Model

```typescript
// config extension
interface StorageConfig {
  backend: "sqlite" | "dolt" | "postgres"

  sqlite?: {
    path?: string           // default: ~/.local/share/kilo/kilo.db
    pragmas?: Record<string, string>
  }

  dolt?: {
    host?: string           // default: 127.0.0.1
    port?: number           // default: 3307
    database?: string       // default: kilo
    user?: string           // default: root
    password?: string       // from env: KILO_DOLT_PASSWORD
    autoCommit?: boolean    // default: true (commit after each session turn)
    branchPerSession?: boolean  // default: false (Phase 5)
    branchPerTool?: boolean     // default: false (Phase 5)
  }

  postgres?: {
    connectionString?: string  // from env: KILO_DATABASE_URL
    poolSize?: number          // default: 10
  }
}
```

---

## 9. Capability Matrix

| Capability | SQLite | Dolt | Postgres |
|-----------|--------|------|----------|
| **Base CRUD** | Yes | Yes | Yes |
| **Transactions** | Sync | Async | Async |
| **Versioned history** | No | Yes (`DOLT_COMMIT`) | No* |
| **Branching** | No | Yes (`DOLT_BRANCH`) | No |
| **Time-travel** | No | Yes (`AS OF`) | No* |
| **Diff** | No | Yes (`dolt_diff`) | No |
| **Vector search** | No | Yes (`VECTOR INDEX`) | Yes (`pgvector`) |
| **Full-text search** | FTS5 | Yes | Yes (`tsvector`) |
| **Server-side filter** | No (in-process) | Yes (wire protocol) | Yes (wire protocol) |
| **Storage hooks** | Yes (via HookableStorage) | Yes | Yes |
| **Zero-config** | Yes (default) | No (server required) | No (server required) |
| **Team sharing** | No (file-based) | Yes (`dolt push/pull`) | Yes (shared server) |

*Postgres temporal tables or triggers could add limited versioning, but it's not native.

---

## 10. Connection to Broader Kilo Vision

This architecture positions Kilo for:

1. **Team AI development**: Shared Dolt server, branch-per-developer, merge conversation insights
2. **Cross-session knowledge**: Gold summaries searchable via semantic search integration
3. **Plugin ecosystem**: Storage hooks enable third-party integrations (Linear, GitHub, custom dashboards)
4. **Memory problem solved**: Server-side filtering (Dolt/Postgres) eliminates GH#6442 entirely
5. **Debuggability**: `dolt_diff` shows exactly what changed each turn — invaluable for agent debugging

The architecture aligns with Kilo's existing multi-surface model (CLI, VSCode, Desktop, Web).
All surfaces talk to the same storage backend via the HTTP server — the storage port is
behind the server, not per-surface.
