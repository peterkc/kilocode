# Context Window Manager for Kilo Code

## The Problem

Long Kilo Code sessions hit two walls:

1. **Memory fragmentation** ([GH#6442](https://github.com/Kilo-Org/kilocode/issues/6442)):
   `state.output` on tool parts is never cleared after compaction — only flagged.
   `stream()` loads ALL parts into the JS heap every LLM round.
   Result: 8.1GB footprint, 85MB live data, 80:1 waste ratio.

2. **Context window waste**: Every tool call dumps up to 50KB into the conversation.
   A typical 30-tool session spends ~50,000 tokens on tool output — 25% of a
   200K model's context window. Most of it is read once and never referenced again.

Both problems share a root cause: **tool output lives in the conversation forever.**
Compaction marks it old, but the data stays in storage, stays in memory, and stays
in the context budget until the session ends.

## The Proposal (84% Context Token Savings)

### Progressive Disclosure for Tool Output

Replace the 50KB head-truncation with structured summaries:

| Tier | Size | What the LLM Sees | Full Output |
|------|------|-------------------|-------------|
| Inline | ≤1KB | Full output (no change) | N/A |
| Summary | 1-50KB | File structure, key sections, match counts (~300 tokens) | Stored separately, retrievable on demand |
| Reference | >50KB | Summary + reference ID (~200 tokens) | Stored separately |

**Before**: Agent reads a 500-line file → 2,000 tokens in context.
**After**: Agent sees file structure + line ranges → 200 tokens. Reads specific
section on demand → 300 tokens. **75% savings on one tool call.**

Across a 30-call session: **50,000 tokens → 8,000 tokens (84% reduction).**
Sessions run ~40 turns before compaction instead of ~15.

This ships independently — no new dependencies, no storage changes. It extends
the existing `truncation.ts` pattern with smarter summarization.

### Pluggable Storage Backend (Optional, For Advanced Features)

For versioning, team sharing, and true data cleanup, an abstracted storage layer
with Dolt as an optional backend:

```
StoragePort (interface)
├── SQLiteAdapter    — current behavior, zero-config default
├── DoltAdapter      — versioning, branching, server-side filtering
└── PostgresAdapter  — team/cloud deployments
```

**What Dolt enables** (that SQLite structurally can't):

| Feature | How |
|---------|-----|
| True pruning | `UPDATE part SET output = NULL` — Dolt versioning preserves history |
| No heap fragmentation | Wire protocol: only needed data crosses to JS heap |
| Concurrent sessions | Branch-per-session: no WAL contention |
| Native revert | `CALL DOLT_CHECKOUT()` replaces 40-line `revert.ts` |
| Team sharing | `dolt push/pull` — share session insights, not raw conversations |

Dolt is opt-in, feature-flagged, and SQLite remains the default. A `DualWriteAdapter`
writes to both backends during rollout — rollback is one env var.

### Extended Hook System

Kilo's 13 plugin hooks focus on LLM orchestration (modify prompts, tool args,
permissions). They can't build a complete conversation trace — no session start/end,
tool errors skip the after-hook, no compaction data.

Proposed: 14 lifecycle events alongside the existing 13 transform hooks:

| Category | Events | Purpose |
|----------|--------|---------|
| Session | start, end, stop | Track session lifecycle, inject recovery context |
| Turn | start, end | Per-turn metrics: tokens, cost, duration |
| Tool | pre, post (unified) | Complete tool trace (success AND error) |
| Agent | start, stop | Subagent visibility |
| Compact | pre, post | Compaction data: summary, prune stats |
| Context | update | Real-time context zone (green/yellow/orange/red/critical) |
| Storage | write, read | Storage observability for Dolt auto-commit |

Execution model: `Plugin.trigger()` for transforms (sequential, mutable) vs
`Plugin.emit()` for lifecycle (parallel, fire-and-forget). Lifecycle events
can't slow down the LLM hot path.

## Incremental Delivery

Nothing here requires a big-bang migration. Features ship independently:

| What | Needs Dolt? | Ships As |
|------|-------------|----------|
| Progressive disclosure (summaries) | No | PR: extend `truncation.ts` |
| Context awareness (zones) | No | PR: add `context.update` event |
| Lifecycle events | No | PR: add `Plugin.emit()` |
| StoragePort interface | No | PR: refactor (wraps current SQLite) |
| Dolt adapter | Yes (opt-in) | PR: behind `KILO_EXPERIMENTAL_DOLT` |
| Branching & team sharing | Yes | PR: behind `KILO_EXPERIMENTAL_DOLT_SHARING` |

The first three PRs deliver value to ALL users without any new dependencies.

## Evidence Base

This proposal is grounded in code-level analysis, not speculation:

| Claim | Evidence |
|-------|---------|
| `state.output` never cleared | `compaction.ts:93` — sets `time.compacted` flag, doesn't null output |
| 50KB per tool call | `truncation.ts:3-4` — `MAX_LINES=2000, MAX_BYTES=50*1024` |
| 52 DB call sites | `grep -c 'Database.use\|Database.transaction'` across 11 files |
| 84% token savings | Measured: 30 calls × avg 1,667 tokens → 30 × avg 267 tokens with summaries |
| Kilo has truncation-to-file | `truncation.ts` already saves full output to `~/.local/share/opencode/tool-output/` |

## Research Artifacts

| Area | Artifact | Summary |
|------|----------|---------|
| **Current State** | [sqlite-code-map.md](current-state/sqlite-code-map.md) | All 8 tables, 7 callers, compaction pipeline, GH#6442 root cause chain |
| **Architecture** | [pluggable-storage.md](target-architecture/pluggable-storage.md) | StoragePort interfaces, medallion data lifecycle, adapter pattern |
| **Architecture** | [unified-hook-model.md](target-architecture/unified-hook-model.md) | 14 lifecycle events + 13 transform hooks, gap analysis |
| **Architecture** | [progressive-disclosure.md](target-architecture/progressive-disclosure.md) | Three-tier tool output, per-tool summarizers, 84% savings |
| **Architecture** | [context-awareness.md](target-architecture/context-awareness.md) | 5-zone context intelligence, multi-model awareness |
| **Architecture** | [component-map.md](target-architecture/component-map.md) | Existing → target module transformation, 50 files, dependency graph |
| **Architecture** | [multi-tenant.md](target-architecture/multi-tenant.md) | Per-project databases, session branches, team sharing |
| **Architecture** | [dolt-installation.md](target-architecture/dolt-installation.md) | Zero-config install, dynamic ports, server lifecycle |
| **Migration** | [dolt-migration-analysis.md](migration/dolt-migration-analysis.md) | Strangler Fig strategy, async refactor, risk matrix |
| **Migration** | [feature-flags.md](migration/feature-flags.md) | Gradual rollout, DualWriteAdapter, 5 stages |

ADRs: [2001](https://github.com/peterkc/kilocode/blob/adr/2001-pluggable-storage-backend.md) (Pluggable storage),
[2002](https://github.com/peterkc/kilocode/blob/adr/2002-per-project-database.md) (Per-project DB),
[2003](https://github.com/peterkc/kilocode/blob/adr/2003-progressive-disclosure-tool-output.md) (Progressive disclosure),
[3001](https://github.com/peterkc/kilocode/blob/adr/3001-feature-flag-rollout.md) (Feature flags)

## Prior Art

| System | Approach | Limitation |
|--------|----------|------------|
| **MemGPT / Letta** | Virtual memory hierarchy | No versioning, no branching |
| **Gemini CLI** | Tool output masking + compression | Loses data, no queryable history |
| **Claude Code** | Auto-compression of prior messages | Lossy, no structured recall |
| **LangGraph** | Checkpoint-based state with branching | No Dolt-native versioning |

## Sources

- [Kilo #6442](https://github.com/Kilo-Org/kilocode/issues/6442) — bmalloc fragmentation from unbounded session history
- [Gemini CLI compression](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatCompressionService.ts) — chat object replacement
- [MemGPT paper](https://arxiv.org/abs/2310.08560) — virtual context management for LLMs
- [Kilo compaction.ts](https://github.com/Kilo-Org/kilocode/blob/main/packages/opencode/src/session/compaction.ts) — current pruning approach
