# Context Window Manager — Git DAG Model for Conversation State

Research into replacing flat conversation history with a branching, pointer-based
context management system backed by Dolt.

## Status: Seed

## Problem Statement

CLI AI agents (Kilo Code, Claude Code, Gemini CLI) manage conversation history as
an append-only log with bolt-on compaction. This causes:

- **Memory fragmentation** (Kilo #6442): full re-hydration of tool outputs into JS heap
  every LLM round. 8.1 GB footprint, 85 MB live data, 80:1 waste ratio.
- **Unbounded growth**: session history grows with every tool call. Compaction marks
  data as "old" but doesn't remove it from storage or prevent re-loading.
- **Brittle revert**: hand-rolled revert systems (40+ lines in Kilo's `revert.ts`)
  that don't compose with compaction.
- **Context pollution**: subagent research, verbose tool outputs, and intermediate
  results all compete for the same flat context window.

Every CLI tool reinvents this. The fix is always the same shape: summarize old stuff,
truncate, hope for the best. None of them treat it as a data management problem.

## Core Idea: Conversation as a Git DAG

```
trunk (context window)         branches (off-context work)
─────────────────────         ────────────────────────────
user: "fix the auth bug"
  │
  ├──branch──> [research: grep auth, read 5 files, analyze]
  │               └── results stored in Dolt, branch closed
  │
  ◄──merge───  ptr: {dolt_ref: "branch/auth-research", summary: "3 files relevant..."}
  │
assistant: "Found the issue in auth.ts:42..."
  │
  ├──branch──> [tool: edit file, run tests, 500 lines output]
  │               └── full output in Dolt, branch closed
  │
  ◄──merge───  ptr: {dolt_ref: "branch/edit-001", summary: "tests pass, 2 files changed"}
  │
assistant: "Fixed. All tests pass."
```

**Trunk** = what the model sees (context window). Only pointers and summaries.
**Branches** = full data from research, tool calls, subagents. Stored in Dolt.
**Merge** = pointer + summary comes back to trunk. Full data queryable on demand.

## Design Principles

### 1. Trunk Never Holds Heavy Payloads

Tool outputs, file contents, test results — all go to branches. The trunk gets a
pointer (Dolt ref) and a summary. The context window stays small and focused.

This directly solves #6442: no bulk string re-hydration because the strings aren't
in the conversation history. They're in Dolt, queryable via SQL when needed.

### 2. Variables, Not Flat History

Research on improving LLM context utilization (MemGPT/Letta, context distillation)
shows that named storage outperforms flat conversation history. Instead of:

```
[message 1] [message 2] [tool output 3] [message 4] [tool output 5] ...
```

Use named variables backed by Dolt tables:

```
working_memory:  {current task, recent decisions, active constraints}
tool_results:    SELECT * FROM tool_calls WHERE session_branch = 'current' ORDER BY ts DESC LIMIT 5
file_context:    SELECT content FROM file_snapshots WHERE path IN (active_files)
research:        SELECT summary FROM research_branches WHERE session = current AND relevance > 0.7
```

The context window is *composed* from these sources each round, not *accumulated*.

### 3. Dolt Is the Native Substrate

Why Dolt, not just any DB:

| Capability | How It's Used |
|------------|---------------|
| Branching | Each subagent/tool call gets a branch. No cross-contamination |
| Merge | Results come back to trunk branch as structured data |
| Time-travel (`AS OF`) | Revert to any conversation state — no hand-rolled revert.ts |
| Diff (`dolt_diff`) | Show what changed between rounds — debuggability for free |
| Server mode | Wire protocol avoids in-process heap allocation entirely |
| SQL | Context composition is just queries, not imperative code |

### 4. Compaction Is Branch Pruning

Instead of marking old tool outputs with `time.compacted` and hoping they don't
get re-loaded (Kilo's current approach):

```sql
-- Compaction = drop old branches
CALL DOLT_BRANCH('-D', 'tool/read-file-001');
CALL DOLT_BRANCH('-D', 'tool/read-file-002');
-- Pointers on trunk still exist, summaries preserved
-- Full data is gone. GC reclaims storage.
```

No fragmentation. No "accidentally recoverable" data. Clean lifecycle.

## Prior Art

| System | Approach | Limitation |
|--------|----------|------------|
| **MemGPT / Letta** | Virtual memory hierarchy (main ctx = registers, archival = disk) | No versioning, no branching, custom storage |
| **Gemini CLI** | Tool output masking + chat compression (replace chat object) | Solves memory but loses data. No queryable history |
| **Kilo Code** | SQLite + compaction + prune | #6442 — doesn't work for long sessions |
| **Claude Code** | Auto-compression of prior messages | Lossy, no structured recall |
| **LangGraph** | Checkpoint-based state with branching | Closest to this model, but no Dolt-native versioning |

## Research Questions

1. **Token overhead of pointers vs inline**: How much context window space do Dolt refs
   + summaries consume vs full tool outputs? Hypothesis: 10-50x reduction.

2. **Retrieval latency**: Can Dolt server-mode queries return relevant context fast
   enough for the LLM round-trip? Target: <100ms per composition query.

3. **Summary quality**: Does pointer-based context degrade model performance vs full
   history? Need benchmarks on task completion with truncated vs pointer-based context.

4. **ckd integration**: Can ck-dolt's graph search power semantic context selection?
   "Which past branches are relevant to the current question?" is a search problem.

5. **Multi-agent composition**: When parallel subagents each have their own branches,
   how does the orchestrator merge results? Conflict resolution semantics.

## Connection to ACF Stack

| Component | Role in Context Manager |
|-----------|------------------------|
| **Dolt** | Storage engine — versioned, branching, server-mode |
| **ckd** | Semantic search over branch contents — relevance-based context selection |
| **bdx** | Session/issue tracking — branches link to beads issues |
| **ACF traces** | Telemetry — token budgets, tool call patterns inform composition policy |
| **ax** (future) | The CLI that ships this as its native context manager |

## Next Steps

- [ ] Survey MemGPT/Letta architecture for variable-storage patterns
- [ ] Prototype: single Dolt branch per tool call in an ACF session
- [ ] Measure token savings (pointer+summary vs full output in context)
- [ ] Evaluate ckd graph queries for relevance-based context composition
- [ ] Map Kilo's `compaction.ts` / `message-v2.ts` to Dolt branch equivalents

## Sources

- [Kilo #6442](https://github.com/Kilo-Org/kilocode/issues/6442) — bmalloc fragmentation from unbounded session history
- [Gemini CLI compression](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatCompressionService.ts) — chat object replacement
- [MemGPT paper](https://arxiv.org/abs/2310.08560) — virtual context management for LLMs
- [Kilo compaction.ts](https://github.com/Kilo-Org/kilocode/blob/main/packages/opencode/src/session/compaction.ts) — current pruning approach
- [ACF traces architecture](https://github.com/peterkc/acf) — Dolt-backed session telemetry
