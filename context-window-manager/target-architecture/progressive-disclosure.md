# Progressive Disclosure: Trunk Summaries, Branch Details

## Problem: Tool Outputs Dominate the Context Window

Every tool call in Kilo dumps its full output (up to 50KB) into the conversation.
The universal truncation ceiling (`truncation.ts`) is:

```
MAX_LINES = 2000
MAX_BYTES = 50 * 1024  (50KB)
```

### Quantifying the Bloat

| Tool | Max Output Per Call | Typical Output | Context Impact |
|------|-------------------|----------------|----------------|
| `read` | 50KB (2000 lines) | 5-20KB | Full file content in context |
| `bash` | 50KB (after truncation) | 1-50KB | Build output, test results, logs |
| `grep` | 50KB (100 matches × long lines) | 2-10KB | Search results with context lines |
| `glob` | 50KB (100 file paths) | 1-3KB | File path listings |
| `webfetch` | 50KB (from 5MB download) | 10-50KB | Web page converted to markdown |
| `websearch` | 50KB (Exa API response) | 5-20KB | Search result snippets |
| `codesearch` | 50KB (up to 50K tokens) | 5-30KB | Code context from Exa |
| `task` | 50KB (subagent last message) | 1-10KB | Subagent response summary |
| `skill` | 50KB (SKILL.md content) | 2-5KB | Skill documentation |

**A typical coding session** with 30 tool calls:
- 5 file reads × 15KB = 75KB
- 10 bash calls × 5KB = 50KB
- 5 grep calls × 5KB = 25KB
- 5 edits × 0.5KB = 2.5KB
- 5 other × 3KB = 15KB
- **Total: ~167KB of tool output alone**

On Claude (200K context ≈ 800KB text), that's ~21% of context from tool outputs.
On GPT-4o (128K context ≈ 512KB text), that's ~33%.

After compaction prunes old outputs, `toModelMessages()` substitutes
`"[Old tool result content cleared]"` — but those messages still occupy
structural tokens (tool call format, metadata, placeholder text).

### The Key Observation

**Most tool output is read once and never referenced again.**

- File contents: read to understand code, then the agent edits specific lines
- Bash output: checked for errors, then the agent moves on
- Grep results: scanned for matches, then the agent reads specific files
- Web content: summarized mentally, then the agent writes code

Yet all this data sits in the context window, consuming tokens, until compaction
eventually marks it as old. There's no mechanism to say "I'm done with this output,
move it to cold storage."

## Current State: Truncation Already Hints at Progressive Disclosure

Kilo already has half the pattern. When output exceeds 50KB:

1. Full text saved to `~/.local/share/opencode/tool-output/<id>` (7-day retention)
2. Conversation receives truncated head + hint:
   `"Output truncated. Use Read with offset, Grep to search, or delegate to Task subagent."`

This IS progressive disclosure — for outputs > 50KB. The problem is everything
≤ 50KB goes into the context verbatim. And 50KB is HUGE for context budget purposes
(~12,500 tokens per call).

## Proposed: Three-Tier Tool Output Model

### Tier 1: Inline (Small, Always in Context)

```
Output ≤ 1KB → directly in conversation
```

Short outputs that are almost always needed: edit confirmations, small file reads,
error messages, short bash output. No reference, no indirection.

Examples:
- `"Edit applied successfully."` (edit.ts)
- `"exit_code: 0\nAll tests passed."` (bash.ts)
- `"3 files matched: src/a.ts, src/b.ts, src/c.ts"` (glob.ts)

### Tier 2: Summary + Reference (Medium, Pointer in Context)

```
Output 1KB–50KB → structured summary in conversation + full output in Dolt
```

This is the core innovation. The tool returns a **structured summary** to the
conversation, plus a **Dolt reference** to the full output:

```typescript
interface ToolOutputTier2 {
  // What the LLM sees in context (~200-500 tokens)
  summary: string
  stats: Record<string, number>   // match_count, line_count, etc.
  highlights: string[]            // key results (first N matches, error lines)

  // What's stored in Dolt (full output, queryable)
  ref: {
    branch: string               // e.g., "tool/read-abc123"
    table: string                // "tool_outputs"
    id: string                   // row ID
  }

  // How to get more detail
  pagination?: {
    total: number
    shown: number
    nextOffset: number
  }
}
```

Example — Reading a 500-line file:

**Current (all in context, ~2KB):**
```
1  import React from 'react'
2  import { useState } from 'react'
3  ... (500 lines of code) ...
500  export default App
```

**Proposed (summary in context, ~200 tokens):**
```
<tool-result tool="read" ref="tool/read-abc123" lines="500" bytes="15234">
  File: src/App.tsx (500 lines, 15KB)
  Language: TypeScript/React
  Exports: App (default), useAppState
  Imports: react, react-router, ./hooks/useAuth, ./components/*
  Key sections:
    L1-15: Imports and type definitions
    L17-45: useAppState hook
    L47-120: App component (main render)
    L122-200: Route configuration
    L202-350: Helper components (NavBar, Footer, Sidebar)
    L352-500: Utility functions and exports

  Use `read src/App.tsx --offset=47 --limit=73` for App component details.
</tool-result>
```

The LLM knows the file structure, key exports, and line ranges — enough to make
decisions about what to edit. If it needs the full content of a specific section,
it reads with offset/limit. That targeted read is Tier 1 (small, inline).

### Tier 3: Reference Only (Large, Never in Context)

```
Output > 50KB → reference only in conversation + full output in Dolt
```

For massive outputs (build logs, large web pages, full test suites):

```
<tool-result tool="bash" ref="tool/bash-def456" lines="5000" bytes="250000">
  Command: npm test
  Exit code: 1
  Duration: 12.3s
  Summary: 47 tests passed, 3 failed
  Failed tests:
    - src/__tests__/auth.test.ts:42 — expected 200, got 401
    - src/__tests__/api.test.ts:88 — timeout after 5000ms
    - src/__tests__/db.test.ts:15 — connection refused

  Full output: 5000 lines (250KB). Query via: tool/bash-def456
</tool-result>
```

## How Each Tool Changes

### Read Tool → Smart Summarizer

```typescript
// tool/read.ts — progressive disclosure version

async function execute(input: ReadInput): Promise<ToolResult> {
  const content = await readFile(input.path, input.offset, input.limit)
  const bytes = Buffer.byteLength(content)

  // Tier 1: Small files inline
  if (bytes <= 1024) {
    return { output: content, metadata: { tier: 1 } }
  }

  // Tier 2: Medium files — summarize + store in Dolt
  const ref = await storage.storeBranch(`tool/read-${callID}`, {
    tool: "read",
    input: { path: input.path, offset: input.offset, limit: input.limit },
    output: content,
    timestamp: Date.now(),
  })

  const summary = await summarizeFile(content, input.path)
  return {
    output: formatTier2({
      tool: "read",
      ref: ref.id,
      file: input.path,
      lines: content.split('\n').length,
      bytes,
      summary,
    }),
    metadata: { tier: 2, ref: ref.id, truncated: false },
  }
}

function summarizeFile(content: string, path: string): string {
  const lines = content.split('\n')
  const ext = path.split('.').pop()

  // Language-aware summarization
  if (isCode(ext)) {
    return summarizeCode(lines, ext)   // imports, exports, classes, functions, line ranges
  } else if (isMarkdown(ext)) {
    return summarizeMarkdown(lines)     // headings, link count, code block count
  } else if (isJSON(ext)) {
    return summarizeJSON(content)       // top-level keys, array lengths, depth
  } else {
    return summarizeText(lines)         // line count, first/last 5 lines
  }
}
```

### Bash Tool → Output Classifier

```typescript
// tool/bash.ts — progressive disclosure version

async function execute(input: BashInput): Promise<ToolResult> {
  const result = await runCommand(input.command, input)
  const bytes = Buffer.byteLength(result.output)

  // Tier 1: Short output inline
  if (bytes <= 1024) {
    return { output: formatBashResult(result), metadata: { tier: 1 } }
  }

  // Store full output in Dolt
  const ref = await storage.storeBranch(`tool/bash-${callID}`, {
    tool: "bash",
    command: input.command,
    output: result.output,
    exitCode: result.exitCode,
    timestamp: Date.now(),
  })

  // Classify output type for smart summarization
  const summary = classifyAndSummarize(result)
  return {
    output: formatTier2({
      tool: "bash",
      ref: ref.id,
      command: input.command,
      exitCode: result.exitCode,
      lines: result.output.split('\n').length,
      bytes,
      summary,
    }),
    metadata: { tier: 2, ref: ref.id },
  }
}

function classifyAndSummarize(result: BashResult): string {
  const output = result.output

  // Test runner output → extract pass/fail/skip counts
  if (looksLikeTestOutput(output)) {
    return summarizeTestResults(output)
  }

  // Build output → extract errors/warnings
  if (looksLikeBuildOutput(output)) {
    return summarizeBuildOutput(output)
  }

  // Git output → extract status/diff summary
  if (looksLikeGitOutput(output)) {
    return summarizeGitOutput(output)
  }

  // Generic → first 5 lines + last 5 lines + error lines
  return summarizeGeneric(output, result.exitCode)
}
```

### Grep Tool → Result Digest

```typescript
// tool/grep.ts — progressive disclosure version

async function execute(input: GrepInput): Promise<ToolResult> {
  const matches = await runGrep(input)

  // Tier 1: Few matches inline
  if (matches.length <= 5 && totalBytes(matches) <= 1024) {
    return { output: formatMatches(matches), metadata: { tier: 1 } }
  }

  // Store full results in Dolt
  const ref = await storage.storeBranch(`tool/grep-${callID}`, {
    tool: "grep",
    pattern: input.pattern,
    path: input.path,
    matches: matches,
    timestamp: Date.now(),
  })

  // Summary: file distribution + top matches
  const fileGroups = groupBy(matches, m => m.file)
  const summary = [
    `Pattern: ${input.pattern}`,
    `Matches: ${matches.length} in ${Object.keys(fileGroups).length} files`,
    '',
    'Distribution:',
    ...Object.entries(fileGroups)
      .sort(([,a], [,b]) => b.length - a.length)
      .slice(0, 10)
      .map(([file, ms]) => `  ${file}: ${ms.length} matches`),
    '',
    'Top matches:',
    ...matches.slice(0, 5).map(m => `  ${m.file}:${m.line}: ${m.text.trim()}`),
  ].join('\n')

  return {
    output: formatTier2({ tool: "grep", ref: ref.id, matchCount: matches.length, summary }),
    metadata: { tier: 2, ref: ref.id },
  }
}
```

## Dolt Storage for Tool Outputs

### Schema

```sql
CREATE TABLE tool_outputs (
    id          VARCHAR(128) PRIMARY KEY,
    session_id  VARCHAR(128) NOT NULL,
    message_id  VARCHAR(128) NOT NULL,
    part_id     VARCHAR(128) NOT NULL,
    call_id     VARCHAR(128) NOT NULL,
    tool        VARCHAR(64)  NOT NULL,
    tier        INT          NOT NULL,     -- 1, 2, or 3
    input       JSON         NOT NULL,     -- tool input args
    output      LONGTEXT,                  -- full output text
    summary     TEXT,                      -- what went into conversation
    metadata    JSON,                      -- tool-specific metadata
    bytes       INT          NOT NULL,
    line_count  INT,
    created_at  DATETIME     NOT NULL,
    INDEX idx_session (session_id),
    INDEX idx_tool (tool),
    INDEX idx_tier (tier)
);
```

### Branching Model

Each tool call gets its own branch (for Tier 2/3):

```
main (conversation trunk)
├── tool/read-abc123     ← full file content
├── tool/bash-def456     ← full command output
├── tool/grep-ghi789     ← full search results
├── tool/webfetch-jkl012 ← full web page markdown
└── ...

Compaction = DELETE FROM tool_outputs WHERE tier >= 2 AND created_at < ?
           + CALL DOLT_BRANCH('-D', 'tool/read-abc123')
           + CALL DOLT_GC()
```

The trunk (main branch) only has summaries and references. Full outputs live
on tool branches. When compaction runs, branches are deleted — but Dolt's commit
history preserves them if recovery is needed.

### Querying Full Output On Demand

When the agent needs more detail (e.g., "show me lines 47-120 of that file"):

```sql
-- Read from the tool branch
SELECT output
FROM tool_outputs AS OF BRANCH 'tool/read-abc123'
WHERE id = 'abc123';

-- Or use AS OF for time-travel if branch was pruned
SELECT output
FROM tool_outputs AS OF 'commit_hash'
WHERE id = 'abc123';
```

For the SQLite adapter (no branching): tool outputs are stored in the same table,
and the `output` column is cleared on compaction (like current behavior, but now
actually cleared instead of just flagged).

## Progressive Disclosure Protocol

### How the Agent Interacts with It

The agent's system prompt includes:

```
## Tool Output Model

Tool results use progressive disclosure:
- **Inline** (≤1KB): Full output in context. No reference needed.
- **Summary + Ref** (1-50KB): Structured summary in context with a `ref` ID.
  Use `read` with `--ref <id>` to retrieve specific sections.
  Use `grep` with `--ref <id>` to search within the output.
- **Reference Only** (>50KB): Only summary and ref. Must query for details.

When you see `<tool-result ref="tool/...">`, the full output is available
via the ref. Only request full output when you need specific details that
aren't in the summary.
```

### Agent Behavior Change

**Before (current — all in context):**
```
Agent: Read src/App.tsx
Tool:  [500 lines of full file content in context]
Agent: [processes 500 lines, uses 3 of them]
Agent: Edit src/App.tsx line 47-48
```

**After (progressive disclosure):**
```
Agent: Read src/App.tsx
Tool:  <tool-result ref="tool/read-abc" lines="500">
         File structure: imports L1-15, App component L47-120, routes L122-200...
       </tool-result>
Agent: [sees structure, knows where to look]
Agent: Read src/App.tsx --offset=47 --limit=73
Tool:  [73 lines of App component — Tier 1, inline]
Agent: Edit src/App.tsx line 52
```

**Token savings:** 500 lines × ~4 tokens/line = 2000 tokens → replaced by ~200 tokens
summary + ~300 tokens targeted read = **75% reduction** for this single tool call.

### Retrieval Tool Extension

Add a `retrieve` command to access stored outputs:

```typescript
// New tool or tool option
{
  name: "retrieve",
  description: "Retrieve full or partial output from a previous tool call",
  input: {
    ref: string,           // tool output reference ID
    offset?: number,       // line offset for pagination
    limit?: number,        // line limit
    grep?: string,         // search within output
    format?: "full" | "section" | "summary",
  }
}
```

Or extend existing tools:
- `read --ref tool/read-abc123 --offset 47 --limit 73`
- `grep --ref tool/bash-def456 "error"`

## Impact Analysis

### Context Window Savings

| Scenario | Current (50KB cap) | Progressive (Summary) | Savings |
|----------|-------------------|----------------------|---------|
| Read 500-line file | ~2000 tokens | ~200 tokens | **90%** |
| Bash test run (1000 lines) | ~4000 tokens | ~300 tokens | **93%** |
| Grep 50 matches | ~2000 tokens | ~400 tokens | **80%** |
| WebFetch page | ~12500 tokens | ~500 tokens | **96%** |
| 30 tool calls session | ~50000 tokens | ~8000 tokens | **84%** |

At 84% savings on tool outputs, a session that currently hits compaction at turn 15
could run to turn 40+ before needing to compact.

### Trade-offs

| Pro | Con |
|-----|-----|
| 84% token savings on tool outputs | Requires extra tool calls for detail |
| Agent makes smarter decisions (sees structure first) | Summarization adds latency per tool call |
| Natural pagination (offset/limit for detail) | Summary quality depends on output type classification |
| Dolt versioning preserves full history | Requires Dolt backend (SQLite fallback = current behavior) |
| Compaction is branch deletion (clean, fast) | Branch-per-tool-call adds Dolt overhead |

### Graceful Degradation

| Backend | Behavior |
|---------|----------|
| **Dolt** | Full progressive disclosure with branching |
| **Postgres** | Progressive disclosure without branching (rows in tool_outputs table) |
| **SQLite** | Current behavior (full output in context, truncation at 50KB) |

The `StoragePort` optional interface probing determines behavior:
```typescript
if (isBranching(storage)) {
  // Dolt: store on branch, return summary
  await storage.createBranch(`tool/${callID}`)
  await storage.storeTool(callID, fullOutput)
  return { summary, ref: `tool/${callID}` }
} else if (isBase(storage)) {
  // SQLite/Postgres: store in table, return summary if table exists
  // Falls back to current behavior if tool_outputs table doesn't exist
}
```

## Relationship to the Git DAG Model

This IS the Git DAG model from the seed research, applied specifically to tools:

```
Trunk (context window)              Branches (full data in Dolt)
─────────────────────              ────────────────────────────
user: "fix the auth bug"
  │
  ├──branch──> [read: src/auth.ts, 500 lines]
  │               └── tool/read-abc → full content in Dolt
  │
  ◄──merge───  summary: "auth.ts: 500 lines, exports AuthProvider, LoginForm.
  │            Key sections: L1-20 imports, L22-80 AuthProvider, L82-150 LoginForm"
  │
agent: "I see the AuthProvider. Let me read the relevant section."
  │
  ├──inline──> [read: src/auth.ts --offset=22 --limit=58]
  │               └── 58 lines, ~1KB → Tier 1, inline
  │
agent: "Found the bug at line 45. Fixing..."
  │
  ├──branch──> [bash: npm test, 1200 lines output]
  │               └── tool/bash-def → full output in Dolt
  │
  ◄──merge───  summary: "npm test: 47 passed, 0 failed. Exit 0. Duration: 8.2s"
```

**Trunk cost of this interaction:**
- Current: 500 + 58 + 1200 lines = ~7000 tokens of tool output
- Progressive: 200 + 58 + 300 tokens = ~558 tokens of tool output
- **92% reduction**

## Smart Summarization by Tool Type

Different tools need different summarization strategies:

| Tool | Summarization Strategy |
|------|----------------------|
| `read` (code) | Imports, exports, classes, functions, line ranges. Language-aware AST if available |
| `read` (markdown) | Headings hierarchy, link count, code block count |
| `read` (json) | Top-level keys, array lengths, nested depth |
| `bash` (tests) | Pass/fail/skip counts, failed test names and first line of error |
| `bash` (build) | Success/fail, error count, warning count, first 3 errors |
| `bash` (git) | Status summary, diff stats, commit info |
| `bash` (generic) | Exit code, line count, first 3 + last 3 lines, error-containing lines |
| `grep` | Match count by file, top N matches, pattern context |
| `glob` | File count, directory distribution, size estimate |
| `webfetch` | Title, headings, link count, content type, estimated word count |
| `websearch` | Result count, top 3 titles + URLs, snippet previews |
| `task` | Subagent conclusion, files touched, key decisions |

### Output Classification

```typescript
function classifyBashOutput(output: string, command: string): OutputType {
  // Test runners
  if (/\d+ (passed|failed|skipped|test)/.test(output)) return "test"
  if (/PASS|FAIL|✓|✗|●/.test(output)) return "test"

  // Build tools
  if (/(error|warning) TS\d+/.test(output)) return "build-typescript"
  if (/error\[E\d+\]/.test(output)) return "build-rust"
  if (/BUILD (SUCCESS|FAILURE)/.test(output)) return "build-generic"

  // Git
  if (command.startsWith("git ")) return "git"

  // Package managers
  if (/added \d+ packages/.test(output)) return "package-install"

  return "generic"
}
```

## Implementation Priority

| Phase | What | Context Savings | Effort |
|-------|------|----------------|--------|
| 1 | Tier threshold (1KB inline, >1KB truncated as today) | 0% (behavior preserved) | Low |
| 2 | Structured summaries for `read` and `bash` | ~60% | Medium |
| 3 | `tool_outputs` table + ref system | ~80% | High (needs StoragePort) |
| 4 | Dolt branching for tool outputs | ~84% + history | High (needs DoltAdapter) |
| 5 | Smart summarization per output type | +5-10% quality | Medium |
| 6 | `retrieve` tool for on-demand detail | Better agent UX | Low |

Phase 2 can ship independently of the storage refactor — it just generates
better summaries without the Dolt storage layer. The summaries replace truncated
output in the conversation, and the full output still goes to the temp file
(`~/.local/share/opencode/tool-output/`).
