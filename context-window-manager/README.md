# Context Window Manager — Git DAG Model for Conversation State

Research into replacing flat conversation history with a branching, pointer-based
context management system backed by Dolt.

## Status: Active

Session history: `58f6803b` (2026-02-28), continuing from `8e491163` (2026-02-28).

## Research Map

### Current State Analysis

Understanding how Kilo Code manages context today.

| Artifact | Contents |
|----------|----------|
| [current-state/sqlite-code-map.md](current-state/sqlite-code-map.md) | All 8 SQLite tables, 7 callers, compaction pipeline, GH#6442 root cause chain |
| [current-state/diagrams/](current-state/diagrams/) | Mermaid source: storage architecture, SQLite touch points |

### Target Architecture

Where we're going: pluggable storage, lifecycle hooks, progressive disclosure.

| Artifact | Contents |
|----------|----------|
| [target-architecture/pluggable-storage.md](target-architecture/pluggable-storage.md) | StoragePort interfaces (Base, Versioned, Branching, Searchable, Hookable), medallion data lifecycle (Bronze/Silver/Gold), adapter implementations, composition root, 5-phase migration path |
| [target-architecture/unified-hook-model.md](target-architecture/unified-hook-model.md) | 14 new lifecycle events modeled after Claude Code + 13 existing transform hooks. Gap analysis vs Claude Code. Plugin.trigger (transforms) vs Plugin.emit (lifecycle) dispatch model |
| [target-architecture/context-awareness.md](target-architecture/context-awareness.md) | Real-time context intelligence: 5-zone classification, trend analysis, composition breakdown, smart compaction strategies. Multi-model awareness (mid-conversation model switching, worstCaseZone, cross-model token estimation) |
| [target-architecture/progressive-disclosure.md](target-architecture/progressive-disclosure.md) | Three-tier tool output model (inline ≤1KB, summary+ref 1-50KB, reference-only >50KB). Per-tool summarization strategies. 84% context token savings. Dolt branch-per-tool storage |
| [target-architecture/diagrams/](target-architecture/diagrams/) | Mermaid source: pluggable storage, unified hooks, progressive tiers |

### Migration Strategy

How to get from current state to target architecture.

| Artifact | Contents |
|----------|----------|
| [migration/dolt-migration-analysis.md](migration/dolt-migration-analysis.md) | 4-phase Strangler Fig strategy (interface extraction → dual-write → read-switch → remove SQLite). Async refactor analysis (~100 call sites). File-by-file migration impact. Risk matrix |

## Design Sources

Three codebases inform this architecture:

| Source | Pattern Borrowed | Applied As |
|--------|-----------------|------------|
| **ckd** (Hexagonal) | Ports & Adapters, optional interface probing, composition root | `StoragePort` base + optional capabilities |
| **ACF Traces** (Medallion) | Bronze → Silver → Gold data lifecycle, hook-driven capture | Messages (Bronze) → SQL Views (Silver) → Compaction summaries (Gold) |
| **Claude Code** (Hooks) | Lifecycle events with rich payloads, context injection | 14 new lifecycle events for full conversation tracing |

## Core Idea: Conversation as a Git DAG

```
trunk (context window)         branches (off-context work)
─────────────────────         ────────────────────────────
user: "fix the auth bug"
  │
  ├──branch──> [read: src/auth.ts, 500 lines]
  │               └── tool/read-abc → full content in Dolt
  │
  ◄──merge───  summary: "auth.ts: 500 lines, exports AuthProvider, LoginForm.
  │            Key sections: L1-20 imports, L22-80 AuthProvider, L82-150 LoginForm"
  │
agent: "I see AuthProvider. Let me read the relevant section."
  │
  ├──inline──> [read: src/auth.ts --offset=22 --limit=58]
  │               └── 58 lines, ~1KB → Tier 1, inline
  │
agent: "Found the bug at line 45. Fixing..."
  │
  ├──branch──> [bash: npm test, 1200 lines output]
  │               └── tool/bash-def → full output in Dolt
  │
  ◄──merge───  summary: "npm test: 47 passed, 0 failed. Exit 0. 8.2s"
```

**Trunk** = what the model sees (only summaries and pointers).
**Branches** = full data from tool calls, stored in Dolt.
**Progressive disclosure** = agent requests detail on demand via refs.

## Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Backend abstraction | Ports & Adapters (ckd pattern) | App layer never imports adapters. Swap via composition root |
| Optional capabilities | Interface probing, not stubs | `if (isBranching(storage))` — zero lies, zero stubs |
| Hook model | Lifecycle + Transform (dual pipeline) | Claude Code model for tracing, Kilo model for behavior shaping |
| Context awareness | Model-relative zones with worstCaseZone | Multi-model sessions need per-model projections |
| Tool output | Three-tier progressive disclosure | 84% token savings. Trunk stays small |
| Data lifecycle | Bronze/Silver/Gold medallion | ACF traces pattern, proven in production |
| Migration | Strangler Fig (4 phases) | Non-breaking, incremental, dual-write safety net |

## Problem Statement

CLI AI agents manage conversation history as append-only logs with bolt-on compaction:

- **Memory fragmentation** (Kilo #6442): 8.1GB footprint, 85MB live, 80:1 waste ratio
- **Unbounded growth**: tool outputs stored forever, only flagged as "old"
- **Brittle revert**: hand-rolled in 40+ lines, doesn't compose with compaction
- **Context pollution**: every tool call dumps up to 50KB into the conversation
- **No intelligence**: binary compaction (full? compact!) with no gradient

## Research Questions

- [x] Map Kilo's SQLite surface → [sqlite-code-map.md](current-state/sqlite-code-map.md)
- [x] Identify migration surface → [dolt-migration-analysis.md](migration/dolt-migration-analysis.md)
- [x] Design pluggable storage → [pluggable-storage.md](target-architecture/pluggable-storage.md)
- [x] Design hook system → [unified-hook-model.md](target-architecture/unified-hook-model.md)
- [x] Design context awareness → [context-awareness.md](target-architecture/context-awareness.md)
- [x] Design progressive disclosure → [progressive-disclosure.md](target-architecture/progressive-disclosure.md)
- [ ] Survey MemGPT/Letta architecture for variable-storage patterns
- [ ] Prototype StoragePort interface extraction (Phase 0)
- [ ] Benchmark Dolt server-mode query latency for session-scoped queries
- [ ] Prototype structured summaries for read/bash tools (Phase 2 of progressive disclosure)
- [ ] Test Drizzle mysql2 driver with Dolt compatibility
- [ ] Evaluate Dolt embedded mode (no server process)
- [ ] Measure token savings (pointer+summary vs full output in context)

## Prior Art

| System | Approach | Limitation |
|--------|----------|------------|
| **MemGPT / Letta** | Virtual memory hierarchy | No versioning, no branching |
| **Gemini CLI** | Tool output masking + compression | Loses data, no queryable history |
| **Kilo Code** | SQLite + compaction + prune | #6442 — doesn't work for long sessions |
| **Claude Code** | Auto-compression | Lossy, no structured recall |
| **LangGraph** | Checkpoint-based with branching | No Dolt-native versioning |

## Sources

- [Kilo #6442](https://github.com/Kilo-Org/kilocode/issues/6442) — bmalloc fragmentation
- [Gemini CLI compression](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatCompressionService.ts)
- [MemGPT paper](https://arxiv.org/abs/2310.08560) — virtual context management for LLMs
- [Kilo compaction.ts](https://github.com/Kilo-Org/kilocode/blob/main/packages/opencode/src/session/compaction.ts)
- [ACF traces architecture](https://github.com/peterkc/acf) — Dolt-backed session telemetry
