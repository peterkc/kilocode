# Multi-Tenant Architecture: Projects, Sessions, Teams

## Current State: Single SQLite, All Projects

Kilo stores everything in one file: `~/.local/share/kilo/kilo.db`.

```
kilo.db
├── project (id = git root-commit SHA)
│   ├── session (FK project_id, cascade delete)
│   │   ├── message (FK session_id)
│   │   │   └── part (FK message_id, denormalized session_id)
│   │   ├── todo (FK session_id)
│   │   └── session_share (FK session_id)
│   └── permission (FK project_id, 1:1)
└── control_account (OAuth, project-independent)
```

**Isolation model**: Project ID is the git repo's first root-commit SHA. Sessions
are scoped to projects via FK. All data shares one file, one WAL lock,
one 5-second busy timeout. Two CLI instances writing simultaneously is
race-condition-free at the SQLite level but has no cross-process event
propagation (each has its own in-memory Bus).

**Limitations**:
- No per-project storage isolation (one corrupted table = all projects affected)
- No team sharing (file-based, single machine)
- No history/versioning (SQLite has no time-travel)
- WAL contention under heavy concurrent use (5s busy timeout)
- The "global" project (no-git fallback) is a catch-all with migration logic

## Design Decision: Per-Project Database vs Shared Database

### Option A: Shared Database with project_id Column

```
kilo_data (single Dolt database)
├── project table
├── session table (project_id column)
├── message table
├── part table
├── tool_outputs table
└── session_summaries table
```

- Pro: Simpler setup (one server, one database)
- Pro: Cross-project queries are natural (JOIN across projects)
- Pro: Matches current SQLite model (minimal migration)
- Con: No per-project branching isolation (branches are database-scoped)
- Con: `dolt push` shares ALL projects (can't share just one)
- Con: Large projects bloat the database for small ones
- Con: One project's GC affects all projects

### Option B: Per-Project Database on Shared Server [Chosen]

```
Dolt Server (port 3307)
├── kilo_project_abc123 (database for project abc123)
│   ├── session, message, part, tool_outputs, session_summaries
│   └── branches: main, session/s1, session/s2, tool/read-xyz
├── kilo_project_def456 (database for project def456)
│   └── ...
├── kilo_global (database for non-git directories)
│   └── ...
└── kilo_meta (server-level metadata)
    ├── projects (registry of all project databases)
    └── control_account (OAuth, server-wide)
```

- Pro: Per-project isolation (branches, history, GC are independent)
- Pro: Selective sharing (`dolt push` per-project database)
- Pro: Clean lifecycle (drop database = remove project entirely)
- Pro: Matches a proven pattern: per-project databases on a shared server
- Con: Database creation overhead per new project (~50ms)
- Con: Cross-project queries need multi-database JOIN (rare use case)
- Con: More databases = more Dolt metadata

**Why this pattern works**: Prior operational experience confirms per-project databases on a shared
server scale well. The operational benefit is proven: adding a project = create
database, not a new process or port. The same pattern scales for Kilo.

## Database Naming Convention

```
kilo_{project_id_prefix}

Where project_id_prefix = first 8 chars of the root-commit SHA (lowercase hex)
```

Examples:
- `kilo_a1b2c3d4` — project with root commit `a1b2c3d4e5f6...`
- `kilo_global` — the catch-all for non-git directories
- `kilo_meta` — server-level metadata (not project-specific)

**Why 8 chars?** Same collision probability as git short SHA (1 in 4 billion).
The full SHA is stored in the `kilo_meta.projects` table for disambiguation.

## Schema: Per-Project Database

Each `kilo_{id}` database has:

### Core Tables (Migrated from Current Schema)

```sql
-- Session: conversation container
CREATE TABLE session (
    id                 VARCHAR(128) PRIMARY KEY,
    parent_id          VARCHAR(128),
    slug               VARCHAR(256),
    directory          VARCHAR(512) NOT NULL,
    title              VARCHAR(512) NOT NULL,
    version            VARCHAR(64) NOT NULL,
    share_url          TEXT,
    summary_additions  INT,
    summary_deletions  INT,
    summary_files      INT,
    summary_diffs      JSON,
    revert             JSON,
    permission         JSON,
    time_created       BIGINT NOT NULL,
    time_updated       BIGINT NOT NULL,
    time_compacting    BIGINT,
    time_archived      BIGINT,
    INDEX idx_parent (parent_id)
);

-- Message: LLM message within a session
CREATE TABLE message (
    id                 VARCHAR(128) PRIMARY KEY,
    session_id         VARCHAR(128) NOT NULL REFERENCES session(id) ON DELETE CASCADE,
    time_created       BIGINT NOT NULL,
    time_updated       BIGINT NOT NULL,
    data               JSON NOT NULL,
    INDEX idx_session (session_id)
);

-- Part: streaming fragment of a message
CREATE TABLE part (
    id                 VARCHAR(128) PRIMARY KEY,
    message_id         VARCHAR(128) NOT NULL REFERENCES message(id) ON DELETE CASCADE,
    session_id         VARCHAR(128) NOT NULL,
    time_created       BIGINT NOT NULL,
    time_updated       BIGINT NOT NULL,
    data               JSON NOT NULL,
    INDEX idx_message (message_id),
    INDEX idx_session (session_id)
);

-- Todo: task list items
CREATE TABLE todo (
    session_id         VARCHAR(128) NOT NULL REFERENCES session(id) ON DELETE CASCADE,
    content            TEXT NOT NULL,
    status             VARCHAR(32) NOT NULL,
    priority           VARCHAR(32) NOT NULL,
    position           INT NOT NULL,
    time_created       BIGINT NOT NULL,
    time_updated       BIGINT NOT NULL,
    PRIMARY KEY (session_id, position),
    INDEX idx_session (session_id)
);

-- Permission: per-project permission ruleset (was per-project in SQLite, now per-database)
CREATE TABLE permission (
    id                 VARCHAR(128) PRIMARY KEY DEFAULT 'default',
    data               JSON NOT NULL,
    time_created       BIGINT NOT NULL,
    time_updated       BIGINT NOT NULL
);

-- Session share: sharing metadata
CREATE TABLE session_share (
    session_id         VARCHAR(128) PRIMARY KEY REFERENCES session(id) ON DELETE CASCADE,
    share_id           VARCHAR(128) NOT NULL,
    secret             VARCHAR(256) NOT NULL,
    url                TEXT NOT NULL,
    time_created       BIGINT NOT NULL,
    time_updated       BIGINT NOT NULL
);
```

### New Tables (Target Architecture)

```sql
-- Tool outputs: progressive disclosure storage (Tier 2/3)
CREATE TABLE tool_output (
    id                 VARCHAR(128) PRIMARY KEY,
    session_id         VARCHAR(128) NOT NULL,
    message_id         VARCHAR(128) NOT NULL,
    part_id            VARCHAR(128) NOT NULL,
    call_id            VARCHAR(128) NOT NULL,
    tool               VARCHAR(64) NOT NULL,
    tier               INT NOT NULL,
    input              JSON NOT NULL,
    output             LONGTEXT,
    summary            TEXT,
    metadata           JSON,
    bytes              INT NOT NULL,
    line_count         INT,
    created_at         BIGINT NOT NULL,
    INDEX idx_session (session_id),
    INDEX idx_tool (tool),
    INDEX idx_tier (tier)
);

-- Session summaries: Gold layer for compaction recovery
CREATE TABLE session_summary (
    session_id         VARCHAR(128) PRIMARY KEY,
    structured         JSON NOT NULL,
    context_md         TEXT NOT NULL,
    embedding          VECTOR(768),
    model              VARCHAR(128),
    token_estimate     INT,
    computed_at        BIGINT NOT NULL
);

-- Context metrics: per-turn token tracking for trend analysis
CREATE TABLE context_metric (
    id                 INT AUTO_INCREMENT PRIMARY KEY,
    session_id         VARCHAR(128) NOT NULL,
    turn_number        INT NOT NULL,
    model_id           VARCHAR(128),
    provider_id        VARCHAR(64),
    context_limit      INT,
    tokens_input       INT,
    tokens_output      INT,
    tokens_cache_read  INT,
    tokens_cache_write INT,
    tokens_total       INT,
    zone               VARCHAR(16),
    recorded_at        BIGINT NOT NULL,
    INDEX idx_session_turn (session_id, turn_number),
    UNIQUE idx_session_turn_unique (session_id, turn_number)
);
```

### Silver Views (Zero-Maintenance)

```sql
-- Active context: what the LLM sees this round
-- Replaces filterCompacted() imperative code
CREATE VIEW v_active_context AS
SELECT m.id as message_id, m.data as msg_data,
       p.id as part_id, p.data as part_data
FROM message m
LEFT JOIN part p ON p.message_id = m.id
WHERE m.time_created > (
    SELECT COALESCE(MAX(m2.time_created), 0)
    FROM message m2
    JOIN part p2 ON p2.message_id = m2.id
    WHERE JSON_EXTRACT(p2.data, '$.type') = 'compaction'
      AND EXISTS (
        SELECT 1 FROM message m3
        WHERE JSON_EXTRACT(m3.data, '$.summary') = true
          AND JSON_EXTRACT(m3.data, '$.parentID') = m2.id
      )
)
  AND (p.id IS NULL OR JSON_EXTRACT(p.data, '$.state.time.compacted') IS NULL)
ORDER BY m.time_created ASC, p.id ASC;

-- Tool call trace
CREATE VIEW v_tool_calls AS
SELECT p.id, p.session_id,
       JSON_EXTRACT(p.data, '$.tool') as tool_name,
       JSON_EXTRACT(p.data, '$.state.status') as status,
       JSON_EXTRACT(p.data, '$.state.time.start') as started_at,
       JSON_EXTRACT(p.data, '$.state.time.end') as ended_at,
       (JSON_EXTRACT(p.data, '$.state.time.end') - JSON_EXTRACT(p.data, '$.state.time.start')) as duration_ms,
       CASE WHEN JSON_EXTRACT(p.data, '$.state.time.compacted') IS NOT NULL
            THEN '[compacted]'
            ELSE SUBSTRING(JSON_EXTRACT(p.data, '$.state.output'), 1, 200)
       END as output_preview
FROM part p
WHERE JSON_EXTRACT(p.data, '$.type') = 'tool';

-- Session timeline
CREATE VIEW v_session_timeline AS
SELECT m.id as message_id, m.session_id,
       JSON_EXTRACT(m.data, '$.role') as role,
       JSON_EXTRACT(m.data, '$.agent') as agent,
       p.id as part_id,
       JSON_EXTRACT(p.data, '$.type') as part_type,
       JSON_EXTRACT(p.data, '$.tool') as tool_name,
       m.time_created, p.time_created as part_time
FROM message m
LEFT JOIN part p ON p.message_id = m.id
ORDER BY m.time_created ASC, p.id ASC;
```

## Schema: Meta Database (kilo_meta)

Server-level data not scoped to any project:

```sql
-- Project registry
CREATE TABLE project (
    id                 VARCHAR(128) PRIMARY KEY,   -- root-commit SHA
    database_name      VARCHAR(128) NOT NULL,       -- kilo_{prefix}
    worktree           VARCHAR(512) NOT NULL,
    vcs                VARCHAR(16),
    name               VARCHAR(256),
    icon_url           TEXT,
    icon_color         VARCHAR(32),
    sandboxes          JSON,
    commands           JSON,
    time_created       BIGINT NOT NULL,
    time_updated       BIGINT NOT NULL,
    time_initialized   BIGINT
);

-- OAuth accounts (server-wide, not project-specific)
CREATE TABLE control_account (
    email              VARCHAR(256) NOT NULL,
    url                TEXT NOT NULL,
    access_token       TEXT NOT NULL,
    refresh_token      TEXT NOT NULL,
    token_expiry       BIGINT,
    active             BOOLEAN NOT NULL DEFAULT FALSE,
    time_created       BIGINT NOT NULL,
    time_updated       BIGINT NOT NULL,
    PRIMARY KEY (email, url)
);

-- Server configuration
CREATE TABLE server_config (
    key                VARCHAR(128) PRIMARY KEY,
    value              JSON NOT NULL,
    updated_at         BIGINT NOT NULL
);
```

## Branching Model: Sessions and Tools

### Branch Naming Convention

```
main                           ← committed conversation state
├── session/{session_id}       ← per-session branch (for isolation)
│   ├── tool/{call_id}         ← per-tool-call branch (Tier 2/3 output)
│   └── subagent/{agent_id}    ← per-subagent branch
└── share/{share_id}           ← snapshot for sharing
```

### Session Lifecycle with Branches

```
1. Session created:
   CALL DOLT_BRANCH('session/{id}', 'main');
   CALL DOLT_CHECKOUT('session/{id}');

2. Each turn:
   INSERT INTO message ...;
   INSERT INTO part ...;
   -- Auto-commit on configurable cadence (per-turn or per-N-turns)
   CALL DOLT_ADD('-A');
   CALL DOLT_COMMIT('-m', 'turn {N}: {summary}');

3. Tool call (Tier 2/3):
   CALL DOLT_BRANCH('tool/{callID}', 'session/{sessionID}');
   -- On tool branch:
   INSERT INTO tool_output ...;    -- full output
   CALL DOLT_COMMIT('-m', 'tool: {name} {callID}');
   -- Back on session branch:
   CALL DOLT_CHECKOUT('session/{sessionID}');
   -- Part in context gets summary + ref to tool branch

4. Compaction:
   -- Commit pre-compaction state
   CALL DOLT_COMMIT('-m', 'pre-compact snapshot');
   -- Delete old tool branches
   CALL DOLT_BRANCH('-D', 'tool/{old_call_1}');
   CALL DOLT_BRANCH('-D', 'tool/{old_call_2}');
   -- Persist Gold summary
   INSERT INTO session_summary ...;
   CALL DOLT_COMMIT('-m', 'compacted: {stats}');

5. Session end:
   -- Merge session branch back to main
   CALL DOLT_CHECKOUT('main');
   CALL DOLT_MERGE('session/{id}');
   -- Or keep branch for future resume
```

### Concurrent Sessions

Two sessions in the same project run on separate branches:

```
main
├── session/abc123  ← VSCode instance, editing auth.ts
└── session/def456  ← CLI instance, running tests

Each writes to its own branch — no WAL contention.
Merge conflicts are handled at merge time (session end),
not during the session.
```

This is structurally impossible with SQLite (single WAL lock).
Dolt branches provide native session isolation.

## Team Sharing

### How Sharing Works with Dolt

```
Developer A (local Dolt):
  kilo_project_abc123/
  ├── main (committed conversation state)
  ├── session/alice-001 (Alice's active session)
  └── session_summary (Gold: Alice's insights)

Developer B (local Dolt):
  kilo_project_abc123/
  ├── main
  ├── session/bob-001 (Bob's active session)
  └── session_summary (Gold: Bob's insights)

Shared Dolt Remote (DoltHub or self-hosted):
  kilo_project_abc123/
  ├── main (merged Gold summaries from both developers)
  └── session_summary (combined team knowledge)
```

### Push/Pull Protocol

```bash
# Alice pushes her session summaries
kilo db push
  → CALL DOLT_PUSH('origin', 'main')
  → Only Gold layer (session_summary) is on main branch
  → Active sessions stay on local branches (not pushed)

# Bob pulls Alice's insights
kilo db pull
  → CALL DOLT_PULL('origin', 'main')
  → Bob now has Alice's session summaries in his Gold layer
  → His semantic search includes Alice's insights
```

**What gets shared:**
- Session summaries (Gold) — what was learned, decided, accomplished
- Context metrics — cost tracking, token usage patterns
- Permission rulesets — shared team permission policies

**What stays local:**
- Active session branches — your in-progress conversations
- Tool output branches — your file reads, bash outputs
- Raw messages/parts (Bronze) — your conversation history

### Conflict Resolution

```sql
-- Dolt's 3-way merge for session_summary:
-- Both Alice and Bob added summaries for different sessions → auto-merge
-- Both modified the same session's summary → conflict → keep both versions

CALL DOLT_MERGE('origin/main');
-- If conflict:
SELECT * FROM dolt_conflicts_session_summary;
-- Resolution: keep all summaries (append-only by nature)
```

Session summaries are naturally conflict-free because each session has a unique
ID and only one person creates its summary. The only conflict scenario is if
two people somehow edit the same session's summary — which shouldn't happen.

## Configuration

```json
// opencode.json / kilo.json
{
  "storage": {
    "backend": "dolt",
    "dolt": {
      "host": "127.0.0.1",
      "port": 3307,
      "autoCommit": "per-turn",
      "branchPerSession": true,
      "branchPerTool": true,
      "sharing": {
        "remote": "origin",
        "url": "https://doltremoteapi.dolthub.com/team/kilo-project",
        "autoPush": false,
        "autoPull": "on-session-start"
      }
    }
  }
}
```

### Auto-Commit Cadence Options

| Setting | Behavior | Trade-off |
|---------|----------|-----------|
| `"per-turn"` | Commit after each user→assistant turn | Best granularity, most commits |
| `"per-5-turns"` | Commit every 5 turns | Balanced |
| `"on-compact"` | Only commit at compaction | Minimal commits, loses history if crash |
| `"manual"` | Only on explicit `kilo db commit` | Full user control |

## Data Directory Layout

```
~/.local/share/kilo/
├── kilo.db                    # SQLite (current, kept as fallback)
├── dolt/                      # Dolt server data directory
│   ├── .dolt-server.yaml      # Server config (auto-generated)
│   ├── kilo_meta/             # Server-level metadata
│   │   └── .dolt/
│   ├── kilo_a1b2c3d4/         # Project database
│   │   └── .dolt/
│   ├── kilo_e5f6g7h8/         # Another project
│   │   └── .dolt/
│   └── kilo_global/           # Non-git directories
│       └── .dolt/
├── tool-output/               # Temp files (current, deprecated for Dolt)
│   └── *.txt                  # 7-day TTL
└── worktree/                  # Git worktrees
    └── {project_id}/{name}/
```

## Database Lifecycle

### Project First Use

```typescript
// storage/adapters/dolt.ts

async function ensureProjectDatabase(projectID: string): Promise<string> {
  const prefix = projectID.substring(0, 8).toLowerCase()
  const dbName = projectID === "global" ? "kilo_global" : `kilo_${prefix}`

  // Check if database exists
  const [rows] = await this.pool.query("SHOW DATABASES LIKE ?", [dbName])
  if (rows.length === 0) {
    // Create database and initialize schema
    await this.pool.query(`CREATE DATABASE ${dbName}`)
    await this.pool.query(`USE ${dbName}`)
    await this.runMigrations()

    // Register in meta database
    await this.pool.query(`USE kilo_meta`)
    await this.pool.query(
      `INSERT INTO project (id, database_name, ...) VALUES (?, ?, ...)`,
      [projectID, dbName, ...]
    )
  }

  return dbName
}
```

### Project Removal

```sql
-- Remove project and all its data
DROP DATABASE kilo_a1b2c3d4;
DELETE FROM kilo_meta.project WHERE id = 'a1b2c3d4...';
```

Cascade is handled by dropping the entire database. No need for FK cascades
across tables — the whole database goes.

## Scaling Characteristics

| Dimension | SQLite (Current) | Dolt (Target) |
|-----------|-----------------|---------------|
| **Projects** | All in one file | Separate database per project |
| **Sessions** | Same table, FK filter | Same database, branch isolation |
| **Concurrent access** | WAL (one writer) | Branch-per-session (many writers) |
| **Team sharing** | Not possible | `dolt push/pull` per-project |
| **History** | None | Dolt commit log, `AS OF` queries |
| **Garbage collection** | N/A (data grows forever) | `DOLT_GC()` per-project, branch pruning |
| **Backup** | Copy `kilo.db` | `dolt push` to remote |
| **Storage growth** | Linear (all data retained) | Content-addressed (deduplication) |
| **Cross-project queries** | Natural (one database) | Multi-database JOIN (rare need) |

## Relationship to Other Design Artifacts

| Artifact | How Multi-Tenant Affects It |
|----------|---------------------------|
| **StoragePort** | `initialize()` must handle `ensureProjectDatabase()` |
| **DoltAdapter** | Connection pool per-project-database, database switching |
| **Progressive disclosure** | `tool_output` table is per-project-database |
| **Session summaries** | Gold layer is per-project, shared via `dolt push` |
| **Context awareness** | `context_metric` table per-project for trend analysis |
| **Lifecycle hooks** | `session.start` triggers database resolution |
| **Migration** | Phase 0 adds `kilo_meta`; Phase 3 creates per-project DBs |

## Operational Lessons from Prior Dolt Migrations

| Lesson | Application to Kilo |
|--------|---------------------|
| Per-project databases on shared server | Same pattern: `kilo_{prefix}` per project |
| launchctl for server management | Kilo manages its own Dolt process (see #9, #10) |
| Adding a project = create database, not new process | `ensureProjectDatabase()` handles this |
| Separate workload profiles | Session data (read-heavy) vs tool outputs (write-heavy) share a server |
| Consistent naming | `kilo_` prefix for all databases |
| CGO_ENABLED build issues | Dolt server is a separate binary, no CGO in Kilo |
