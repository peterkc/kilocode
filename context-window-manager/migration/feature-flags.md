# Feature Flags: Gradual Dolt Rollout

## Lesson from Beads: SQLite → Dolt Was Too Abrupt

A prior project switched from SQLite embedded mode to Dolt server mode in one
release. Users hit:

- Dolt not installed → crash on startup
- Server not running → silent data loss
- Lock file corruption → manual recovery
- Schema differences → migration failures
- No rollback path → stuck on broken state

**The fix**: Feature flags that let both backends coexist. Users opt in, test,
report issues, and only after confidence is established does the default change.

## Kilo's Existing Flag System

Kilo uses env-var-based flags in `flag/flag.ts`:

```typescript
// Existing patterns:
export const KILO_EXPERIMENTAL = truthy("KILO_EXPERIMENTAL")           // master switch
export const KILO_EXPERIMENTAL_PLAN_MODE = KILO_EXPERIMENTAL || truthy("KILO_EXPERIMENTAL_PLAN_MODE")
export const KILO_ENABLE_EXA = truthy("KILO_ENABLE_EXA") || KILO_EXPERIMENTAL
export const KILO_DISABLE_AUTOCOMPACT = truthy("KILO_DISABLE_AUTOCOMPACT")
```

**Convention**: `KILO_EXPERIMENTAL_*` for opt-in features, `KILO_DISABLE_*` for opt-out.
`KILO_EXPERIMENTAL` is the master switch — enables ALL experimental features.

We follow this convention exactly.

## Flag Definitions

### Phase 1: Storage Abstraction (Experimental)

```typescript
// flag/flag.ts additions

// Master: opt into Dolt storage backend
export const KILO_EXPERIMENTAL_DOLT =
  KILO_EXPERIMENTAL || truthy("KILO_EXPERIMENTAL_DOLT")

// Sub-flags (only meaningful when DOLT is enabled)
export const KILO_EXPERIMENTAL_DOLT_DUAL_WRITE =
  KILO_EXPERIMENTAL_DOLT && (truthy("KILO_EXPERIMENTAL_DOLT_DUAL_WRITE") ?? true)
  // Default ON when Dolt is enabled — writes to both SQLite and Dolt

export const KILO_EXPERIMENTAL_DOLT_READ_FROM_DOLT =
  truthy("KILO_EXPERIMENTAL_DOLT_READ_FROM_DOLT")
  // Default OFF — reads from SQLite. Flip to read from Dolt.

export const KILO_EXPERIMENTAL_DOLT_AUTO_DOWNLOAD =
  !truthy("KILO_DISABLE_DOLT_DOWNLOAD")
  // Default ON — auto-download Dolt binary. Can be disabled.
```

### Phase 2: Progressive Disclosure (Independent)

```typescript
// Can ship without Dolt — works with SQLite too
export const KILO_EXPERIMENTAL_PROGRESSIVE_DISCLOSURE =
  KILO_EXPERIMENTAL || truthy("KILO_EXPERIMENTAL_PROGRESSIVE_DISCLOSURE")

export const KILO_EXPERIMENTAL_SMART_SUMMARY =
  KILO_EXPERIMENTAL_PROGRESSIVE_DISCLOSURE || truthy("KILO_EXPERIMENTAL_SMART_SUMMARY")
  // Smart tool output summaries (read, bash, grep)
```

### Phase 3: Lifecycle Events

```typescript
export const KILO_EXPERIMENTAL_LIFECYCLE_EVENTS =
  KILO_EXPERIMENTAL || truthy("KILO_EXPERIMENTAL_LIFECYCLE_EVENTS")
  // Emit new lifecycle events (session.start/end, tool.post, etc.)
```

### Phase 4: Context Awareness

```typescript
export const KILO_EXPERIMENTAL_CONTEXT_AWARENESS =
  KILO_EXPERIMENTAL || truthy("KILO_EXPERIMENTAL_CONTEXT_AWARENESS")
  // Real-time context zone tracking + agent system prompt injection
```

### Phase 5: Dolt Advanced (Branching, Versioning)

```typescript
export const KILO_EXPERIMENTAL_DOLT_BRANCHING =
  KILO_EXPERIMENTAL_DOLT && truthy("KILO_EXPERIMENTAL_DOLT_BRANCHING")
  // Session branches, tool branches, branch-per-tool-call

export const KILO_EXPERIMENTAL_DOLT_SHARING =
  KILO_EXPERIMENTAL_DOLT && truthy("KILO_EXPERIMENTAL_DOLT_SHARING")
  // Team sharing via dolt push/pull
```

## Rollout Stages

```
Stage 1: EXPERIMENTAL_DOLT (dual-write, SQLite reads)
  ├── SQLite is primary (reads + writes)
  ├── Dolt is shadow (writes only, for verification)
  ├── Checksum comparison catches discrepancies
  └── Users: power users who opt in via env var

Stage 2: EXPERIMENTAL_DOLT + READ_FROM_DOLT (Dolt reads, dual-write)
  ├── Dolt is primary for reads
  ├── SQLite still receives writes (rollback safety)
  ├── Functional parity verified
  └── Users: beta testers

Stage 3: DOLT becomes default, SQLite is fallback
  ├── New installs default to Dolt
  ├── Existing installs keep SQLite until manual switch
  ├── KILO_DISABLE_DOLT to opt out
  └── Users: everyone (with escape hatch)

Stage 4: SQLite deprecated
  ├── Warning on startup if using SQLite
  ├── Migration tool: kilo db migrate --from-sqlite
  ├── SQLite adapter kept but unmaintained
  └── Users: stragglers prompted to migrate

Stage 5: SQLite removed (future, only if Dolt proves stable)
  └── May never happen — SQLite as zero-dep fallback has value
```

## Coexistence Architecture

### Dual-Write Mode (Stage 1-2)

```typescript
// storage/adapters/dual-write.ts

export class DualWriteAdapter implements StoragePort {
  constructor(
    private primary: StoragePort,     // SQLite (Stage 1) or Dolt (Stage 2)
    private secondary: StoragePort,   // Dolt (Stage 1) or SQLite (Stage 2)
  ) {}

  async createSession(session: Session.Info): Promise<void> {
    await this.primary.createSession(session)
    try {
      await this.secondary.createSession(session)
    } catch (error) {
      // Log but don't fail — secondary is best-effort
      log.warn("dual-write secondary failed", {
        operation: "createSession",
        error: error.message,
      })
    }
  }

  async streamMessages(sessionID: string): AsyncGenerator<MessageV2.WithParts> {
    // Always read from primary
    return this.primary.streamMessages(sessionID)
  }

  async updatePart(part: MessageV2.Part): Promise<void> {
    await this.primary.updatePart(part)
    try {
      await this.secondary.updatePart(part)
    } catch (error) {
      log.warn("dual-write secondary failed", {
        operation: "updatePart",
        partID: part.id,
        error: error.message,
      })
    }
  }

  // ... all other methods follow same pattern
}
```

### Composition Root with Feature Flags

```typescript
// storage/wire.ts

export namespace StorageFactory {
  export async function create(config: StorageConfig): Promise<StoragePort> {

    // Stage 0: No flags, pure SQLite (current behavior)
    if (!Flag.KILO_EXPERIMENTAL_DOLT) {
      return new SQLiteAdapter(config.sqlite ?? { path: Database.Path })
    }

    // Stage 1: Dual-write, SQLite primary
    const sqlite = new SQLiteAdapter(config.sqlite ?? { path: Database.Path })

    let dolt: StoragePort
    try {
      const binary = await DoltInstall.ensure()
      const server = await DoltServer.ensureRunning()
      dolt = new DoltAdapter({ ...config.dolt, server })
    } catch (error) {
      log.warn("dolt unavailable, falling back to sqlite-only", { error })
      return sqlite
    }

    if (Flag.KILO_EXPERIMENTAL_DOLT_READ_FROM_DOLT) {
      // Stage 2: Dolt primary, SQLite shadow
      return new DualWriteAdapter(dolt, sqlite)
    }

    // Stage 1: SQLite primary, Dolt shadow
    return new DualWriteAdapter(sqlite, dolt)
  }
}
```

### Data Verification (Dual-Write Integrity Check)

```typescript
// storage/verification.ts

export async function verifyConsistency(
  primary: StoragePort,
  secondary: StoragePort,
  sessionID: string,
): Promise<VerificationResult> {
  const primaryMsgs = await collect(primary.streamMessages(sessionID))
  const secondaryMsgs = await collect(secondary.streamMessages(sessionID))

  const issues: string[] = []

  // Check message count
  if (primaryMsgs.length !== secondaryMsgs.length) {
    issues.push(`message count: primary=${primaryMsgs.length}, secondary=${secondaryMsgs.length}`)
  }

  // Check message IDs match
  for (let i = 0; i < Math.min(primaryMsgs.length, secondaryMsgs.length); i++) {
    if (primaryMsgs[i].info.id !== secondaryMsgs[i].info.id) {
      issues.push(`message ${i}: id mismatch`)
    }
    // Check part count per message
    if (primaryMsgs[i].parts.length !== secondaryMsgs[i].parts.length) {
      issues.push(`message ${primaryMsgs[i].info.id}: part count mismatch`)
    }
  }

  return {
    consistent: issues.length === 0,
    issues,
    primaryCount: primaryMsgs.length,
    secondaryCount: secondaryMsgs.length,
  }
}
```

### CLI Verification Command

```bash
$ kilo db verify

Verifying SQLite ↔ Dolt consistency...

Session abc-123: ✓ consistent (42 messages, 156 parts)
Session def-456: ✓ consistent (18 messages, 67 parts)
Session ghi-789: ✗ MISMATCH
  - message count: SQLite=25, Dolt=24
  - message msg_00024: part count mismatch (SQLite=3, Dolt=2)

2/3 sessions consistent. Run 'kilo db repair' to fix mismatches.
```

## Rollback Safety

### At Any Stage, Users Can Revert

```bash
# Disable Dolt entirely (back to pure SQLite)
export KILO_EXPERIMENTAL_DOLT=false
kilo   # starts with SQLite, Dolt server still running but unused

# Or in kilo.json
{ "storage": { "backend": "sqlite" } }

# Or stop the Dolt server
kilo db stop
```

### Data Preservation on Rollback

- SQLite always has a complete copy (dual-write ensures this through Stage 2)
- Dolt data is preserved in `~/.local/share/kilo/dolt/` (not deleted)
- Re-enabling Dolt picks up where it left off
- No data loss in either direction

### Emergency Recovery

```bash
# If Dolt is corrupted and Kilo won't start
export KILO_EXPERIMENTAL_DOLT=false   # bypass Dolt entirely
kilo                                   # starts on SQLite

# Then fix Dolt offline
kilo db repair     # attempts automatic repair
# or
rm -rf ~/.local/share/kilo/dolt/   # nuclear option, re-sync from SQLite
```

## Metrics Collection Under Feature Flags

When `KILO_EXPERIMENTAL_DOLT` is enabled, collect operational metrics:

```typescript
interface DoltMetrics {
  // Performance
  queryLatency: { avg: number; p95: number; p99: number }
  writeLatency: { avg: number; p95: number; p99: number }
  dualWriteOverhead: number   // ms added by secondary write

  // Reliability
  secondaryFailures: number   // dual-write secondary errors
  consistencyChecks: number   // how many verified
  inconsistencies: number     // how many failed

  // Usage
  doltDiskUsage: number       // bytes
  sqliteDiskUsage: number     // bytes
  branchCount: number         // active branches
  commitCount: number         // total commits
}
```

These metrics feed into the `context.update` lifecycle event and can be surfaced
via `kilo db status --metrics`. They inform the decision to advance to the next
rollout stage.

## Config File Integration

Feature flags work at TWO levels:

### 1. Environment Variables (Existing Kilo Pattern)

```bash
# Quick enable for testing
export KILO_EXPERIMENTAL_DOLT=true
kilo
```

### 2. Config File (Persistent)

```json
// ~/.kilo/config.json or project's kilo.json
{
  "storage": {
    "backend": "dolt",
    "dolt": {
      "host": "127.0.0.1",
      "port": 3307,
      "managed": true
    }
  },
  "experimental": {
    "dolt": true,
    "doltDualWrite": true,
    "doltReadFromDolt": false,
    "progressiveDisclosure": true,
    "contextAwareness": false
  }
}
```

Config file settings override env vars. The `experimental` section maps to
`KILO_EXPERIMENTAL_*` flags but persists across sessions.

### Resolution Order

```
1. Environment variable (highest priority — for quick testing)
2. Project config (kilo.json in project root)
3. User config (~/.kilo/config.json)
4. Default (false for experimental features)
```

## Feature Flag Lifecycle

```
EXPERIMENTAL_*     →    ENABLE_*           →    Default ON        →    DISABLE_*
(opt-in, env var)       (config option)         (new installs)         (opt-out)

Beta testers            Early adopters          General release         Legacy support
Flag required           Config option           No config needed        Flag to revert
Dual-write              Dolt primary            Dolt only*              SQLite removed*
Metrics collected       Stable metrics          Production              —

* "Dolt only" may never happen — SQLite as zero-dep fallback has permanent value
```

## Progressive Feature Independence

Features are NOT all-or-nothing. Each can roll out independently:

```
                        Requires Dolt?   Can Ship Alone?
Progressive Disclosure     No               Yes ← START HERE
Context Awareness          No               Yes
Lifecycle Events           No               Yes
Smart Summaries            No               Yes
StoragePort Abstraction    No               Yes (SQLite adapter)
Dolt Backend               Yes              Yes (behind flag)
Branching                  Yes              After Dolt stable
Team Sharing               Yes              After branching
```

**Progressive disclosure and context awareness can ship on SQLite.** They don't
need Dolt at all. This means we can deliver value to users immediately while
Dolt support matures behind feature flags.

## Relationship to Migration Path (#8)

The migration phases map directly to feature flags:

| Migration Phase | Feature Flag | Default |
|----------------|-------------|---------|
| Phase 0: Interface extraction | None (internal refactor) | N/A |
| Phase 1: Async foundation | None (internal refactor) | N/A |
| Phase 2: Progressive disclosure | `EXPERIMENTAL_PROGRESSIVE_DISCLOSURE` | OFF |
| Phase 3: Dolt adapter | `EXPERIMENTAL_DOLT` | OFF |
| Phase 4: Dual-write | `EXPERIMENTAL_DOLT_DUAL_WRITE` | ON (when Dolt enabled) |
| Phase 5: Read from Dolt | `EXPERIMENTAL_DOLT_READ_FROM_DOLT` | OFF |
| Phase 6: Dolt default | Remove `EXPERIMENTAL_`, add `DISABLE_DOLT` | ON |
| Phase 7: Lifecycle events | `EXPERIMENTAL_LIFECYCLE_EVENTS` | OFF → ON |
| Phase 8: Context awareness | `EXPERIMENTAL_CONTEXT_AWARENESS` | OFF → ON |
| Phase 9: Branching | `EXPERIMENTAL_DOLT_BRANCHING` | OFF |
| Phase 10: Team sharing | `EXPERIMENTAL_DOLT_SHARING` | OFF |
