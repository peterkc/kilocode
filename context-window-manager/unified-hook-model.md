# Unified Hook Model: Lifecycle Events + Transform Hooks

## Design Decision

Kilo Code needs TWO kinds of hooks, not one:

| Hook Type | Purpose | Model Source | Can Modify? | Execution |
|-----------|---------|-------------|-------------|-----------|
| **Lifecycle Events** | Capture the full conversation tape | Claude Code | No (observe + inject context) | Fire-and-forget, async |
| **Transform Hooks** | Shape LLM behavior | Kilo current | Yes (mutate output) | Sequential, awaited |

Kilo currently has only Transform Hooks (13 of them). It needs Lifecycle Events
to support traces, team features, storage backends, and debugging.

## Gap Analysis: What Kilo Cannot Capture Today

### 10 Critical Gaps

| # | Missing Event | Why It Matters | How Claude Code Solves It |
|---|-------------|----------------|--------------------------|
| 1 | Session start/resume | Can't distinguish new vs resumed, can't inject recovery context | `SessionStart` with `source: startup/resume/compact/clear` |
| 2 | Session end/close | Can't persist Gold summaries, can't track duration | `SessionEnd` with `reason: clear/logout/exit` |
| 3 | Tool errors in after-hook | `tool.execute.after` skips errors → incomplete trace | `PostToolUse` fires for BOTH success and error |
| 4 | Subagent lifecycle | Subagent conversations are black boxes | `SubagentStart`/`SubagentStop` with internal state |
| 5 | Clean stop signal | Can't differentiate agent finish vs crash vs user interrupt | `Stop` event fires on clean completion |
| 6 | Compaction data | `session.compacted` has only sessionID | `PreCompact` + post-compact `SessionStart(source=compact)` |
| 7 | Complete LLM response | Must reconstruct from streaming parts | Transcript JSONL has full response |
| 8 | Token/cost accounting | Buried in message metadata bus events | Available in `PostToolUse` response headers |
| 9 | Storage lifecycle | No hooks on DB reads/writes | N/A (Claude Code doesn't have this either — we ADD it) |
| 10 | MCP output inconsistency | MCP after-hook gets raw protocol format | N/A (Claude Code doesn't use MCP the same way) |

### What Kilo CAN Capture (Existing Strengths)

- User messages (via `chat.message` transform hook)
- Tool input/output for built-in tools (via `tool.execute.before/after`)
- System prompt assembly (via `experimental.chat.system.transform`)
- LLM parameters (via `chat.params`)
- Message history pre-LLM (via `experimental.chat.messages.transform`)
- Permission decisions (via `permission.ask`)
- Turn boundaries (via `session.turn.open/close` bus events — Kilocode addition)
- File changes (via `file.edited` bus events)

## Proposed Lifecycle Events

### Category 1: Session Lifecycle

```typescript
interface LifecycleHooks {
  // Fires when a session begins (new, resumed, or post-compaction)
  "session.start"?: (event: {
    sessionID: string
    source: "new" | "resume" | "compact" | "clear"
    projectID: string
    model: string
    directory: string
    parentSessionID?: string  // for forked/child sessions
  }) => Promise<{ context?: string[] }>  // inject additional context

  // Fires when a session ends (any reason)
  "session.end"?: (event: {
    sessionID: string
    reason: "close" | "clear" | "crash" | "logout" | "timeout"
    duration: number          // ms
    turnCount: number
    totalTokens: number
    totalCost: number
  }) => Promise<void>

  // Fires when agent completes its response (not user interrupt)
  "session.stop"?: (event: {
    sessionID: string
    finishReason: string      // "end_turn", "tool-calls", "length", etc.
    messageID: string         // last assistant message
  }) => Promise<void>
}
```

**Why `session.start` matters for Dolt**: This is where the Dolt adapter creates
or checks out the session branch. For `source: "resume"`, it checks out the
existing branch. For `source: "compact"`, it commits pre-compaction state first.

**Why `session.end` matters for Gold**: This is where the Gold persist pipeline
runs — compute structured summary, generate context_md, store in session_summaries.

### Category 2: Turn Lifecycle

```typescript
interface LifecycleHooks {
  // Fires when user submits a prompt (before ANY processing)
  "turn.start"?: (event: {
    sessionID: string
    prompt: string            // raw user text
    turnNumber: number
    attachments?: string[]    // file paths, images
  }) => Promise<{ context?: string[] }>

  // Fires after assistant finishes responding
  "turn.end"?: (event: {
    sessionID: string
    turnNumber: number
    assistantMessageID: string
    tokens: {
      input: number
      output: number
      cache: { read: number; write: number }
      total: number
    }
    cost: number              // USD estimate
    finishReason: string
    toolCallCount: number
    duration: number          // ms
  }) => Promise<void>
}
```

**Why this matters for traces**: Turn boundaries are THE key structuring event.
Every downstream analysis (tool call rate, cost tracking, response quality) is
scoped to turns. Kilo has `session.turn.open/close` bus events (Kilocode addition)
but they carry minimal data.

### Category 3: Tool Lifecycle (Unified Success + Error)

```typescript
interface LifecycleHooks {
  // Fires before any tool executes (built-in, MCP, or Task)
  "tool.pre"?: (event: {
    sessionID: string
    callID: string
    tool: string              // tool name
    input: Record<string, any>
    isMCP: boolean
    isSubagent: boolean
  }) => Promise<{
    decision?: "allow" | "deny" | "ask"  // permission gate (like Claude Code)
  }>

  // Fires after any tool completes (success OR error — unified)
  "tool.post"?: (event: {
    sessionID: string
    callID: string
    tool: string
    input: Record<string, any>
    output: string            // normalized output text (even for MCP)
    status: "completed" | "error"
    error?: string            // populated when status = "error"
    duration: number          // ms
    metadata?: Record<string, any>
  }) => Promise<{ context?: string[] }>
}
```

**Key design choice**: `tool.post` fires for BOTH success and error. This is the
Claude Code model (`PostToolUse` fires regardless of outcome). Kilo's current
`tool.execute.after` only fires on success — errors go to a different bus event
with a different shape. This fragmentation makes trace building unreliable.

**MCP normalization**: `tool.post` always provides `output` as a string, even for
MCP tools. The adapter normalizes `result.content[].text` to a joined string before
the hook fires. This fixes gap #10.

### Category 4: Agent Lifecycle

```typescript
interface LifecycleHooks {
  // Fires when a subagent starts
  "agent.start"?: (event: {
    sessionID: string         // parent session
    agentID: string
    agentType: string         // "general", "explore", "code", etc.
    prompt: string            // task prompt
    parentCallID: string      // the Task tool call that spawned this
  }) => Promise<void>

  // Fires when a subagent finishes
  "agent.stop"?: (event: {
    sessionID: string         // parent session
    agentID: string
    agentType: string
    result: string            // summary returned to parent
    duration: number
    turnCount: number
    toolCallCount: number
  }) => Promise<void>
}
```

### Category 5: Compaction Lifecycle

```typescript
interface LifecycleHooks {
  // Fires before compaction starts (last chance to save state)
  "compact.pre"?: (event: {
    sessionID: string
    trigger: "auto" | "manual"
    tokensBefore: number
    messageCount: number
  }) => Promise<void>

  // Fires after compaction completes
  "compact.post"?: (event: {
    sessionID: string
    summary: string           // the LLM-generated continuation summary
    tokensAfter: number
    prunedParts: number
    prunedTokens: number
    compactionBoundary: string  // message ID where history was cut
  }) => Promise<void>
}
```

**Why `compact.pre` matters for Dolt**: This is where the adapter commits the
pre-compaction state. Like ACF's PreCompact hook, it ensures the full history
is preserved in Dolt's commit log before the working set is pruned.

**Why `compact.post` matters for Gold**: The summary text and prune stats feed
directly into the `session_summaries` Gold table.

### Category 6: Storage Lifecycle (NEW — Neither Claude Code Nor Kilo Has This)

```typescript
interface LifecycleHooks {
  // Fires on every storage write operation
  "storage.write"?: (event: {
    sessionID: string
    table: "session" | "message" | "part" | "todo" | "permission"
    operation: "insert" | "update" | "delete"
    rowID: string
    data?: Record<string, any>  // the written data (optional, may be large)
  }) => Promise<void>

  // Fires on every storage read operation
  "storage.read"?: (event: {
    sessionID: string
    table: string
    operation: "select" | "stream"
    rowCount: number
    duration: number          // ms
  }) => Promise<void>
}
```

This is novel — neither Claude Code nor Kilo has storage-level hooks. We ADD this
because the pluggable storage backend needs observability. Use cases:

- **Dolt auto-commit**: `storage.write` triggers `DOLT_ADD` + `DOLT_COMMIT` on configurable cadence
- **Replication**: Mirror writes to a team Dolt server
- **Performance monitoring**: Track read durations to detect slow queries
- **Audit trail**: Log who wrote what when (multi-user scenarios)

## Execution Model

### Two Pipelines, One Interface

```typescript
// plugin/hooks.ts — the unified Hooks interface

export interface Hooks {
  // ─── Lifecycle Events (observe + inject context) ───
  "session.start"?: LifecycleHandler<SessionStartEvent, { context?: string[] }>
  "session.end"?: LifecycleHandler<SessionEndEvent, void>
  "session.stop"?: LifecycleHandler<SessionStopEvent, void>
  "turn.start"?: LifecycleHandler<TurnStartEvent, { context?: string[] }>
  "turn.end"?: LifecycleHandler<TurnEndEvent, void>
  "tool.pre"?: LifecycleHandler<ToolPreEvent, { decision?: "allow" | "deny" | "ask" }>
  "tool.post"?: LifecycleHandler<ToolPostEvent, { context?: string[] }>
  "agent.start"?: LifecycleHandler<AgentStartEvent, void>
  "agent.stop"?: LifecycleHandler<AgentStopEvent, void>
  "compact.pre"?: LifecycleHandler<CompactPreEvent, void>
  "compact.post"?: LifecycleHandler<CompactPostEvent, void>
  "storage.write"?: LifecycleHandler<StorageWriteEvent, void>
  "storage.read"?: LifecycleHandler<StorageReadEvent, void>

  // ─── Transform Hooks (mutate output — existing Kilo model) ───
  "chat.message"?: TransformHandler<ChatMessageInput, ChatMessageOutput>
  "chat.params"?: TransformHandler<ChatParamsInput, ChatParamsOutput>
  "chat.headers"?: TransformHandler<ChatHeadersInput, ChatHeadersOutput>
  "tool.execute.before"?: TransformHandler<ToolExecBeforeInput, ToolExecBeforeOutput>
  "tool.execute.after"?: TransformHandler<ToolExecAfterInput, ToolExecAfterOutput>
  "tool.definition"?: TransformHandler<ToolDefInput, ToolDefOutput>
  "permission.ask"?: TransformHandler<PermAskInput, PermAskOutput>
  "shell.env"?: TransformHandler<ShellEnvInput, ShellEnvOutput>
  "command.execute.before"?: TransformHandler<CmdExecBeforeInput, CmdExecBeforeOutput>
  "experimental.chat.system.transform"?: TransformHandler<SysTransformInput, SysTransformOutput>
  "experimental.chat.messages.transform"?: TransformHandler<MsgTransformInput, MsgTransformOutput>
  "experimental.session.compacting"?: TransformHandler<CompactingInput, CompactingOutput>
  "experimental.text.complete"?: TransformHandler<TextCompleteInput, TextCompleteOutput>

  // ─── Registration Hooks (existing) ───
  "tool"?: ToolRegistrationHandler
  "auth"?: AuthRegistrationHandler
  "event"?: EventObserverHandler   // keep for backward compat (Bus.subscribeAll bridge)
  "config"?: ConfigHandler
}
```

### Dispatch Rules

```typescript
// plugin/index.ts — dispatch logic

export namespace Plugin {
  // Transform hooks: sequential, awaited, mutable output (EXISTING behavior)
  async function trigger(name: TransformHookName, input, output) {
    for (const hook of hooks) {
      if (hook[name]) await hook[name](input, output)
    }
    return output
  }

  // Lifecycle events: parallel, fire-and-forget, no mutation (NEW)
  async function emit(name: LifecycleHookName, event) {
    const results = await Promise.allSettled(
      hooks
        .filter(h => h[name])
        .map(h => h[name]!(event))
    )
    // Collect context injections from hooks that return { context }
    const context = results
      .filter(r => r.status === "fulfilled" && r.value?.context)
      .flatMap(r => r.value.context)
    return context.length > 0 ? context : undefined
  }
}
```

**Key difference**:
- `Plugin.trigger()` (transform) = sequential, awaited, mutable output
- `Plugin.emit()` (lifecycle) = parallel, fire-and-forget, immutable event + optional context injection

This means lifecycle events can't slow down the hot path. A slow traces plugin
doesn't block the LLM call.

## Comparison: Before and After

### Building a Trace — Current Kilo

```typescript
// Today: fragile, incomplete, requires stitching multiple sources
export default async function(input) {
  return {
    "event": async ({ event }) => {
      // Bus events: ~40 types, inconsistent shapes
      // Must filter and normalize each one
      // Missing: tool errors, session end, subagents, compaction data
      recordBusEvent(event)
    },
    "tool.execute.after": async ({ tool, sessionID, callID, args }, output) => {
      // Only fires on success
      // MCP tools have different output shape
      recordToolResult(tool, output)
    },
    "chat.message": async ({ sessionID }, { message, parts }) => {
      recordUserMessage(message)
    },
  }
}
```

### Building a Trace — Unified Model

```typescript
// Target: complete, consistent, clean
export default async function(input) {
  return {
    "session.start": async (event) => {
      initSession(event.sessionID, event.source, event.model)
      return { context: [await getRecoveryContext(event.sessionID)] }
    },
    "turn.start": async (event) => {
      recordTurn(event.sessionID, event.turnNumber, event.prompt)
    },
    "tool.post": async (event) => {
      // Fires for BOTH success and error, consistent shape
      recordToolCall(event.tool, event.input, event.output, event.status, event.duration)
    },
    "agent.stop": async (event) => {
      recordSubagent(event.agentID, event.agentType, event.result, event.duration)
    },
    "turn.end": async (event) => {
      recordTurnMetrics(event.tokens, event.cost, event.finishReason)
    },
    "compact.post": async (event) => {
      persistGold(event.sessionID, event.summary, event.tokensAfter)
    },
    "session.end": async (event) => {
      finalizeSession(event.sessionID, event.reason, event.duration, event.totalCost)
    },
  }
}
```

## How This Connects to the Storage Architecture

The unified hook model feeds directly into the medallion data lifecycle:

```
Lifecycle Events (13 new)
    │
    ├── session.start ──────> Bronze: INSERT sessions
    ├── turn.start ─────────> Bronze: INSERT hook_events (user prompt)
    ├── tool.pre ───────────> Bronze: INSERT hook_events (tool input)
    ├── tool.post ──────────> Bronze: INSERT hook_events (tool output + duration)
    ├── agent.start/stop ──> Bronze: INSERT hook_events (subagent lifecycle)
    ├── turn.end ──────────> Bronze: INSERT hook_events (token/cost metrics)
    ├── compact.pre ───────> Gold: COMMIT pre-compaction state (Dolt)
    ├── compact.post ──────> Gold: INSERT session_summaries
    ├── session.end ───────> Bronze: UPDATE sessions (ended_at)
    │                        Gold: Final persist
    │                        Dolt: DOLT_COMMIT + optional DOLT_GC
    │
    └── storage.write/read ─> Dolt: auto-commit, replication, monitoring

Silver Views (always current, zero maintenance):
    v_active_context, v_tool_calls, v_session_timeline
```

## Migration: Adding Lifecycle Events to Kilo

### Non-Breaking Additions

All lifecycle events are NEW hook names. No existing plugin breaks.

| Priority | Hook | Where to Add Plugin.emit() | Effort |
|----------|------|---------------------------|--------|
| P0 | `session.start` | `session/index.ts` after `Session.createNext()` | Low |
| P0 | `session.end` | New — add to session close/archive path | Medium |
| P0 | `tool.post` (unified) | `session/prompt.ts` after tool execution (all 3 paths) | Medium |
| P1 | `turn.start` | `session/prompt.ts` at `SessionPrompt.prompt()` entry | Low |
| P1 | `turn.end` | `session/prompt.ts` at loop exit | Low |
| P1 | `compact.pre/post` | `session/compaction.ts` around `process()` | Low |
| P2 | `agent.start/stop` | `session/prompt.ts` Task tool handling | Medium |
| P2 | `session.stop` | `session/prompt.ts` at clean exit | Low |
| P3 | `storage.write/read` | `storage/db.ts` wrapper around `Database.use()` | Medium |

### Phase 0 (Can Ship Independently)

The lifecycle events don't require the StoragePort refactor. They can be added
to the current codebase as a standalone PR. This makes them Phase 1 credibility
material (kc-934) — adding observability without changing storage.

## External Hook Execution (Optional Future)

Claude Code's hooks run as **external processes** (shell commands via stdin/stdout JSON).
Kilo's hooks run **in-process** (TypeScript functions).

For team deployments, external execution may be valuable:
- Language-agnostic (Python traces pipeline, Go monitoring agent)
- Process isolation (slow/buggy plugin can't crash Kilo)
- Configurable via settings file (no npm install needed)

This is a Phase 3+ consideration. The in-process model works for now, and
Kilo's `PluginInput.$` (Bun shell) already gives plugins subprocess capability.
