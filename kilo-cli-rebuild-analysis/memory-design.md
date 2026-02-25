# Memory Design: AHP Memory Protocol on ckd/Dolt

**Beads**: acf-qv7wn
**Depends on**: ckd shipping as first production consumer
**Related**: `../kilo-cli-vs-claude-code/agent-harness-protocol.md` (AHP spec)

## Problem

Every agentic CLI uses flat markdown files for memory:

| CLI | Memory Implementation | Limitations |
|-----|----------------------|-------------|
| Claude Code | `MEMORY.md` (~200 lines) | Manual curation, no search, no versioning, grows unbounded |
| Kilo CLI | Memory Bank (markdown files) | No versioning, no structure, no cross-project |
| OpenCode | None | No persistent memory at all |
| ACF | `MEMORY.md` + topic files + beads notes | Better, but still grep-through-markdown |

Flat files cannot be queried, versioned, searched semantically, shared across projects, or merged without conflicts.

## Solution: ckd/Dolt as Memory Backend

```
Agent session
    │
    ├── SessionStart: exportForPrompt(project, 4000 tokens)
    │   └── SQL: high-confidence entries → markdown → system prompt
    │
    ├── During: persist(), correct(), recall()
    │   └── SQL: INSERT/UPDATE/SELECT on memory tables
    │
    └── SessionEnd: endSession(summary, files, decisions)
        └── SQL: INSERT session_context for handoff
```

## Schema

### memory (core entries)

```sql
CREATE TABLE memory (
    id          VARCHAR(36) PRIMARY KEY,
    project     VARCHAR(255) NOT NULL,
    scope       ENUM('project', 'user', 'global') NOT NULL,
    topic       VARCHAR(255) NOT NULL,
    key         VARCHAR(255) NOT NULL,
    value       TEXT NOT NULL,
    confidence  FLOAT DEFAULT 1.0,
    source      VARCHAR(50),       -- 'user_correction', 'auto_capture', 'session_learning'
    session_id  VARCHAR(36),
    created_at  TIMESTAMP DEFAULT NOW(),
    updated_at  TIMESTAMP DEFAULT NOW(),
    expires_at  TIMESTAMP NULL,
    UNIQUE(project, scope, topic, key)
);
```

**Scope levels**:
- `project` — knowledge specific to one codebase (e.g., "this project uses Bun")
- `user` — personal preferences across projects (e.g., "always use conventional commits")
- `global` — universal patterns (e.g., "Dolt server needs DOLT_ROOT_PASSWORD")

### corrections (what was wrong → what's right)

```sql
CREATE TABLE corrections (
    id              VARCHAR(36) PRIMARY KEY,
    memory_id       VARCHAR(36) REFERENCES memory(id),
    old_value       TEXT NOT NULL,
    new_value       TEXT NOT NULL,
    reason          TEXT,
    session_id      VARCHAR(36),
    corrected_at    TIMESTAMP DEFAULT NOW()
);
```

Corrections track the learning trajectory — what the agent believed, what was wrong, and why. This is audit trail + training signal.

### session_context (handoff state)

```sql
CREATE TABLE session_context (
    session_id      VARCHAR(36) PRIMARY KEY,
    project         VARCHAR(255) NOT NULL,
    started_at      TIMESTAMP NOT NULL,
    ended_at        TIMESTAMP,
    summary         TEXT,
    active_issues   JSON,
    files_touched   JSON,
    decisions_made  JSON
);
```

Session context enables handoff: "here's what the last session did, here's what's in progress."

## Membrane Interface

```typescript
interface MemoryProvider {
    // Read
    recall(topic: string, key?: string): Promise<MemoryEntry[]>
    recallByProject(project: string): Promise<MemoryEntry[]>
    search(query: string): Promise<MemoryEntry[]>

    // Write
    persist(entry: MemoryEntry): Promise<void>
    correct(id: string, newValue: string, reason: string): Promise<void>
    forget(id: string): Promise<void>

    // Session lifecycle
    startSession(sessionId: string, project: string): Promise<void>
    endSession(sessionId: string, summary: string): Promise<void>

    // Bulk
    getSessionHandoff(sessionId: string): Promise<HandoffContext>
    exportForPrompt(project: string, tokenBudget: number): Promise<string>
}
```

### ckd Implementation

```typescript
class CkdMemoryProvider implements MemoryProvider {
    async recall(topic, key?) {
        return ckd.query(`
            SELECT * FROM memory
            WHERE project = ? AND topic = ?
            ${key ? 'AND key = ?' : ''}
            ORDER BY confidence DESC, updated_at DESC
        `, [this.project, topic, key].filter(Boolean))
    }

    async search(query) {
        // Semantic search via ckd embeddings (when available)
        // Falls back to LIKE search
        return ckd.search(query, { table: 'memory' })
    }

    async persist(entry) {
        return ckd.query(`
            INSERT INTO memory (id, project, scope, topic, key, value, confidence, source, session_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON DUPLICATE KEY UPDATE value = ?, confidence = ?, updated_at = NOW()
        `, [...])
    }

    async correct(id, newValue, reason) {
        const old = await ckd.query('SELECT value FROM memory WHERE id = ?', [id])
        await ckd.query('INSERT INTO corrections ...', [id, old.value, newValue, reason])
        await ckd.query('UPDATE memory SET value = ?, updated_at = NOW() WHERE id = ?', [newValue, id])
    }

    async exportForPrompt(project, tokenBudget) {
        const entries = await ckd.query(`
            SELECT topic, key, value FROM memory
            WHERE project = ? AND confidence > 0.5
            ORDER BY confidence DESC, updated_at DESC
        `, [project])

        // Format as markdown, truncate to token budget
        let output = '# Memory\n\n'
        let tokens = 0
        for (const entry of entries) {
            const line = `- **${entry.topic}/${entry.key}**: ${entry.value}\n`
            const lineTokens = estimateTokens(line)
            if (tokens + lineTokens > tokenBudget) break
            output += line
            tokens += lineTokens
        }
        return output
    }
}
```

### Flat File Fallback

For AHP compliance without ckd:

```typescript
class FlatFileMemoryProvider implements MemoryProvider {
    // Reads/writes .agents/memory/*.md
    // Groups by topic (one file per topic)
    // MEMORY.md is the auto-generated export
    // No semantic search, no confidence decay, no corrections tracking
}
```

## Unique Capabilities (ckd-only)

### 1. Temporal Queries

```sql
-- What did we learn this week?
SELECT * FROM memory WHERE updated_at > DATE_SUB(NOW(), INTERVAL 7 DAY)

-- Most frequently corrected beliefs (instability signal)
SELECT m.topic, m.key, COUNT(c.id) as correction_count
FROM memory m JOIN corrections c ON m.id = c.memory_id
GROUP BY m.topic, m.key ORDER BY correction_count DESC
```

### 2. Confidence Decay

```sql
-- Entries not referenced in 30 days lose confidence
UPDATE memory SET confidence = confidence * 0.9
WHERE updated_at < DATE_SUB(NOW(), INTERVAL 30 DAY)
  AND confidence > 0.1

-- Only high-confidence entries enter the system prompt
-- Low-confidence entries are still queryable via recall()
```

### 3. Cross-Project Knowledge

```sql
-- Patterns that work in multiple projects (most transferable)
SELECT topic, key, value, COUNT(DISTINCT project) as projects
FROM memory WHERE scope = 'global'
GROUP BY topic, key, value HAVING projects > 1
ORDER BY projects DESC

-- "What do I know about Dolt across all projects?"
SELECT * FROM memory WHERE value LIKE '%dolt%' OR topic LIKE '%dolt%'
```

### 4. Dolt Branching for Experiments

```bash
# Try a new approach — branch memory
dolt checkout -b experiment/new-pattern

# Agent works, memories accumulate on branch
# If approach works:
dolt merge experiment/new-pattern
# If not:
dolt branch -D experiment/new-pattern
```

### 5. Team Memory Sharing

```bash
# Push your learned patterns to team
dolt push origin main

# Pull teammate's corrections
dolt pull origin main
# Dolt handles row-level 3-way merge
# Different memory keys = no conflicts
```

### 6. Session Handoff

```sql
-- What was the last session working on?
SELECT summary, active_issues, files_touched, decisions_made
FROM session_context
WHERE project = ? ORDER BY started_at DESC LIMIT 1

-- Inject into next session's system prompt as context
```

## How This Replaces ACF's Current Memory

| ACF Today | ckd Memory |
|-----------|------------|
| `MEMORY.md` (200 lines, manual) | `exportForPrompt()` — auto-selects by confidence + recency |
| `memory/spec-patterns.md` | `recall('spec-patterns')` — SQL query |
| `patterns/lessons/quick-captures.md` | `persist({source: 'auto_capture'})` — structured |
| `/remember "always use bun"` | `persist({scope: 'user', topic: 'preferences', key: 'runtime', value: 'bun'})` |
| Manual consolidation at ~10 entries | SQL dedup: `GROUP BY topic, key` |
| Beads `--append-notes` | `session_context.decisions_made` — structured JSON |

## AHP Memory Protocol (Revised for ckd)

```
AHP Memory Protocol v0.2

Tier 1 (flat files — AHP-Core compliance):
  .agents/memory/MEMORY.md          auto-loaded, token-budgeted
  .agents/memory/*.md               topic files, recalled by name

Tier 2 (ckd/Dolt — AHP-Full compliance):
  memory table                      structured, queryable, confidence-scored
  corrections table                 learning trajectory, audit trail
  session_context table             handoff state, continuity
  semantic search                   via ckd embeddings
  cross-project knowledge           scope = 'global', shareable via dolt push
```

## Bootstrap Strategy

ckd's first production consumer is memory, not code search:

```
Phase 1: Memory tables in ckd (small, high-value, validates Dolt)
Phase 2: code_inspect tool (full AST search, validates tree-sitter integration)
Phase 3: Semantic memory search (validates embedding pipeline)
```

Each phase validates ckd incrementally. Memory is the Stone Soup entry.

## Open Questions

- Q1: Should memory tables live in the same Dolt DB as code index, or separate?
- Q2: How to handle memory migration when switching between ckd and flat-file providers?
- Q3: Should confidence decay be automatic (cron/hook) or on-demand (at session start)?
- Q4: How much of session_context overlaps with the traces DB? Should they share a schema?
- Q5: Should the corrections table feed back into model fine-tuning data exports?
