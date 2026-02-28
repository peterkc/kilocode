---
status: Proposed
date: 2026-02-28
category: Architecture
deciders: [peterkc]
tags: [context-window, tools, progressive-disclosure, performance]
---

# ADR 2003: Three-Tier Progressive Disclosure for Tool Output

## Context

Every tool call in Kilo dumps up to 50KB of output into the conversation context.
The universal truncation ceiling (`truncation.ts`) is 2000 lines or 50KB. A
typical 30-tool-call session spends ~50,000 tokens on tool output — 25% of a
200K-token model's context window.

Most tool output is read once and never referenced again. File contents are read
to understand code, then specific lines are edited. Bash output is checked for
errors, then the agent moves on. Yet all this data persists in the context until
compaction flags it as old (without actually removing it — GH#6442).

Kilo already has half the pattern: when output exceeds 50KB, the full text is
saved to a temp file and the conversation gets a truncated head. The problem is
the 50KB threshold is too high — even "small" outputs of 5-20KB accumulate rapidly.

## Decision Drivers

- Context window is the most constrained resource in long sessions
- Tool output dominates context usage (25-33% of budget on typical sessions)
- Agents rarely need full output — they need structure (what's in the file) then detail (specific sections)
- Kilo's existing truncation already saves full output to temp files
- Progressive disclosure is a proven UX pattern (show overview, drill into detail)

## Considered Options

### Option 1: Lower the Truncation Threshold

Reduce MAX_BYTES from 50KB to 5KB. Same head-truncation, just tighter.

- Good: Minimal code change (one constant)
- Bad: Agents lose context they may need (blind truncation)
- Bad: No structural summary — just fewer lines
- Bad: Doesn't help the agent decide what to read next

### Option 2: LLM-Generated Summaries Per Tool Call

Run a small model to summarize each tool output before placing it in context.

- Good: High-quality summaries
- Bad: Latency per tool call (+500ms-2s for LLM call)
- Bad: Cost per tool call (API billing)
- Bad: Summary quality depends on model choice

### Option 3: Three-Tier Structured Disclosure [Chosen]

Route tool output by size into three tiers:

| Tier | Size | In Context | Full Output |
|------|------|-----------|-------------|
| 1: Inline | ≤1KB | Full output | N/A |
| 2: Summary + Ref | 1-50KB | Structured summary (~300 tokens) | Stored in Dolt/temp file |
| 3: Reference Only | >50KB | Summary + ref (~200 tokens) | Stored in Dolt/temp file |

Summaries are **deterministic** (AST-based for code, pattern-matching for bash/test output), not LLM-generated. Zero latency, zero cost.

- Good: 84% token savings (50K → 8K tokens per 30-call session)
- Good: Agent sees structure first, requests detail on demand
- Good: No LLM cost — summaries are deterministic pattern matching
- Good: Graceful degradation (SQLite uses temp files, Dolt uses branches)
- Good: Extends Kilo's existing truncation pattern naturally
- Neutral: Per-tool summarizers need maintenance as tools change
- Bad: Agents need training to use `--offset`/`--ref` for detail retrieval

## Decision

**Option 3**: Three-tier progressive disclosure with deterministic summarizers.

### Summarization Strategies by Tool

| Tool | Summary Method |
|------|---------------|
| `read` (code) | Language-aware: imports, exports, classes, functions, line ranges |
| `read` (markdown) | Heading hierarchy, link count, code block count |
| `read` (JSON) | Top-level keys, array lengths, depth |
| `bash` (tests) | Pass/fail/skip counts, failed test names |
| `bash` (build) | Success/fail, error count, first 3 errors |
| `bash` (git) | Status summary, diff stats |
| `bash` (generic) | Exit code, first 3 + last 3 lines, error lines |
| `grep` | Match count by file, top N matches |
| `webfetch` | Title, headings, word count |

### Storage by Backend

| Backend | Tier 2/3 Storage | Recovery |
|---------|-----------------|----------|
| SQLite | Temp file (7-day TTL, existing behavior) | File path in metadata |
| Dolt | `tool_output` table on tool branch | `AS OF` time-travel |
| Postgres | `tool_output` table (row) | Standard row query |

## Consequences

### Positive

- 84% reduction in tool output tokens (measured: 50K → 8K per session)
- Sessions run ~40 turns before compaction instead of ~15
- Agent develops better reading habits (structure first, detail on demand)
- Can ship on SQLite without Dolt (Phase 2 is independent)

### Negative

- Per-tool summarizers are maintenance burden
- Agents may need extra tool calls for detail (net token cost unclear)
- Summary quality varies by output type (generic fallback is weaker)

### Neutral

- `tool/retrieve.ts` (new tool) provides on-demand detail access
- Feature-flagged: `KILO_EXPERIMENTAL_PROGRESSIVE_DISCLOSURE`

## Related

- [Research: progressive-disclosure.md](https://github.com/peterkc/kilocode/blob/research/context-window-manager/target-architecture/progressive-disclosure.md)
- [Research: context-awareness.md](https://github.com/peterkc/kilocode/blob/research/context-window-manager/target-architecture/context-awareness.md)
- ADR 2001: Pluggable Storage Backend
