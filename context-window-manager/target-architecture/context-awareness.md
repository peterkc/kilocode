# Context Awareness: Real-Time Context Window Intelligence

## Problem

Kilo's context management is binary: full? compact. There's no gradient:

```
Current Kilo:     [─────────────── OK ───────────────|COMPACT!]
                  0%                                  ~95%    100%

What we need:     [─── Green ───|── Yellow ──|─ Orange ─|Red|!]
                  0%            50%          75%       90% 95%
```

**Three deficiencies:**

1. **No agent-side awareness**: The LLM agent doesn't know how full its context is.
   It can't make intelligent decisions about tool output verbosity, when to summarize,
   or whether to spawn subagents for heavy research.

2. **No proactive recommendations**: The user gets no warning before the hard compaction
   limit. One moment everything is fine, the next moment the conversation is summarized
   and context is lost.

3. **No smart compaction**: Compaction is all-or-nothing at the overflow point. There's
   no partial pruning, no "compact only tool outputs older than N turns", no
   "suggest /compact when you're at 75%".

## Current State of the Art

### Prior Art: External Context Tracking

- Fires on PostToolUse for Bash/Write/Edit/NotebookEdit only
- Parses the full transcript JSONL to compute token counts
- Three threshold bands: 50%, 75%, 90% (fire-once per band)
- Injects `"Context: 52% (104K/200K). Consider /compact."` as system-reminder
- **Limitations**: Must parse the entire transcript file (can be 50MB+), only fires
  on 4 tool types, no gradient within bands, no smart recommendations

### Kilo Current (sidebar/header)

- Computes percentage from last assistant message tokens in UI (SolidJS memo)
- Available in `sidebar.tsx:51-60` and `header.tsx:49-59`
- **UI-only** — the agent has no access to this information
- `isOverflow()` in `compaction.ts` is the only server-side check: binary yes/no

### Neither Has: Intelligence

Neither system uses context usage to make intelligent decisions. Both just report
a number. The opportunity is to make context awareness a first-class input to the
agent's decision-making.

## Proposed: Context Intelligence System

### Multi-Model Awareness (Critical Design Constraint)

Kilo Code supports mid-conversation model switching via:
- `local.model.cycle(1/-1)` — keybind to cycle through recent models
- `local.model.cycleFavorite(1/-1)` — cycle favorites
- `local.model.set({providerID, modelID})` — command palette selection

Model is resolved **per-turn** at `prompt.ts:1014`:
```typescript
const model = input.model ?? agent.model ?? (await lastModel(sessionID))
```

Each user message records its model: `msg.model = {providerID, modelID}`.
The effective context limit changes whenever the user switches models.

**Impact on context awareness:**

| Problem | Example | Solution |
|---------|---------|----------|
| Zone instability | 140K used: 70% on Claude 200K, 109% on GPT-4o 128K | Use absolute tokens + per-model zone calculation |
| Trend analysis breaks | Growth rate computed on Claude, applied to GPT-4o | Track tokens per turn (model-independent) + project per-model |
| Composition varies | Same text = different token count per tokenizer | Store raw character count, estimate per model on demand |
| Sudden overflow | Switch from 1M Gemini to 128K GPT-4o triggers instant compact | Pre-switch warning: "This model has 128K limit, you're at 140K" |

**Design principle:** Track context state in **absolute tokens** (model-independent),
but compute zones and projections **relative to the current model's budget**.

### New Lifecycle Event: `context.update`

Add to the unified hook model:

```typescript
interface LifecycleHooks {
  // Fires after every LLM response with current context state
  "context.update"?: (event: ContextState) => Promise<{
    context?: string[]   // inject recommendations into next turn
    action?: "compact" | "prune" | "none"  // smart compaction trigger
  }>
}

interface ContextState {
  sessionID: string
  turnNumber: number

  // Token accounting (from most recent LLM response)
  tokens: {
    input: number
    output: number
    reasoning: number
    cache: { read: number; write: number }
    total: number           // current context window size
  }

  // Current model budget (recalculated each turn)
  budget: {
    model: string           // e.g., "claude-sonnet-4-20260514"
    providerID: string
    contextLimit: number     // model's max context
    inputLimit: number       // model's max input (may differ)
    outputReserved: number   // reserved for output generation
    usable: number           // effective usable = limit - reserved
    used: number             // current usage
    remaining: number        // usable - used
    percentage: number       // used / usable * 100
  }

  // Model switch detection
  modelSwitch: {
    switched: boolean        // true if model changed from previous turn
    previousModel?: string   // what it was before
    previousLimit?: number   // what the limit was before
    budgetDelta?: number     // positive = more room, negative = tighter
  }

  // Trend (computed over last N turns, model-independent)
  trend: {
    tokensPerTurn: number    // avg token growth per turn (absolute)
    turnsRemaining: number   // estimated turns to overflow on CURRENT model
    growthRate: "stable" | "growing" | "accelerating"
    // Per-model projections (if user has used multiple models)
    projections?: {
      model: string
      limit: number
      turnsRemaining: number
      percentage: number
    }[]
  }

  // Zone classification (relative to CURRENT model)
  zone: "green" | "yellow" | "orange" | "red" | "critical"

  // Cross-model zone (what zone would we be in on the smallest recent model?)
  worstCaseZone: "green" | "yellow" | "orange" | "red" | "critical"

  // Composition breakdown (in current model's token estimate)
  composition: {
    systemPrompt: number     // tokens in system prompt
    history: number          // tokens in conversation history
    toolOutputs: number      // tokens in non-compacted tool outputs
    compactedPlaceholders: number  // tokens in "[Old tool result cleared]" placeholders
  }
}
```

### Zone Definitions

```typescript
const ZONES = {
  green:    { min: 0,  max: 50, action: "none",    advisory: null },
  yellow:   { min: 50, max: 75, action: "none",    advisory: "suggest_pruning" },
  orange:   { min: 75, max: 85, action: "prune",   advisory: "recommend_compact" },
  red:      { min: 85, max: 95, action: "compact",  advisory: "urge_compact" },
  critical: { min: 95, max: 100, action: "compact", advisory: "force_compact" },
}
```

### Multi-Model Zone Behavior

Zones are always computed against the **current model's budget**, but we track
a `worstCaseZone` across all recently-used models to prevent surprises:

```typescript
function computeZone(state: ContextState): { zone: Zone; worstCaseZone: Zone } {
  // Current model zone
  const zone = classifyZone(state.budget.percentage)

  // Worst-case: what if user switches to the smallest model they've used recently?
  const recentModels = getRecentModels(state.sessionID, 5)
  const smallestLimit = Math.min(...recentModels.map(m => m.limit.context))
  const worstPct = (state.tokens.total / smallestLimit) * 100
  const worstCaseZone = classifyZone(worstPct)

  return { zone, worstCaseZone }
}
```

**Why `worstCaseZone` matters:** If a user is on Gemini 1M (green, 14%) but has
also used GPT-4o (128K) in this session, `worstCaseZone` would be `critical` (109%).
The system can warn: "You're green on Gemini, but switching back to GPT-4o would
overflow. Consider compacting before switching models."

### Model Switch Pre-Validation

A new transform hook intercepts model switches BEFORE they take effect:

```typescript
// NEW transform hook
"model.switch.before"?: TransformHandler<{
  sessionID: string
  currentModel: { id: string; limit: number }
  targetModel: { id: string; limit: number }
  currentTokens: number
}, {
  allow: boolean
  warning?: string   // shown to user before switching
}>
```

Example behavior:
```
User presses Ctrl+M to cycle to GPT-4o (128K)
  → model.switch.before fires
  → currentTokens: 140K, targetModel.limit: 128K
  → 140K > 128K → return { allow: true, warning:
      "Context (140K) exceeds GPT-4o limit (128K). Auto-compact will trigger." }
  → User sees warning, can cancel or proceed
```

### Agent-Aware Model Context Display

The system prompt section adapts to model switches:

```typescript
function contextBudgetSection(state: ContextState): string {
  const lines = []

  // Model switch notification
  if (state.modelSwitch.switched) {
    const delta = state.modelSwitch.budgetDelta!
    if (delta < 0) {
      lines.push(`⚠ Model switched to ${state.budget.model} (${fmt(state.budget.contextLimit)} context).`)
      lines.push(`Budget reduced by ${fmt(Math.abs(delta))} tokens.`)
      lines.push(`Zone changed: now at ${state.budget.percentage}%.`)
    } else {
      lines.push(`Model switched to ${state.budget.model} (${fmt(state.budget.contextLimit)} context).`)
      lines.push(`Additional ${fmt(delta)} tokens available.`)
    }
  }

  // Zone-based content (existing logic)
  if (state.zone === "green" && !state.modelSwitch.switched) return ""
  // ... rest of zone handling ...

  // Multi-model projection (if multiple models used in session)
  if (state.trend.projections && state.trend.projections.length > 1) {
    lines.push(`\nContext by model:`)
    for (const proj of state.trend.projections) {
      lines.push(`  ${proj.model}: ${proj.percentage}% (~${proj.turnsRemaining} turns left)`)
    }
  }

  return lines.join("\n")
}
```

This means the agent sees:
```
⚠ Model switched to gpt-4o (128K context).
Budget reduced by 72K tokens.
Zone changed: now at 87% (Red).

Context by model:
  claude-sonnet-4: 43% (~22 turns left)
  gpt-4o: 87% (~2 turns left)
  gemini-2.5-pro: 11% (~120 turns left)

Warning: Consider /compact. On current model, ~2 turns remain.
```
```

### Where It Fires

After every `finish-step` in the LLM stream (same place `isOverflow()` currently
checks). The token data is already available from the step finish event:

```typescript
// session/processor.ts — after finish-step event
case "finish-step": {
  const usage = value.usage
  // ... existing code ...

  // NEW: Emit context state
  const contextState = computeContextState(usage, model, turnNumber)
  const hookResult = await Plugin.emit("context.update", contextState)

  // Smart compaction: honor hook decisions
  if (hookResult?.action === "compact") {
    needsCompaction = true
  } else if (hookResult?.action === "prune") {
    await SessionCompaction.prune({ sessionID })
  }

  // Existing overflow check (fallback if no hook)
  if (!needsCompaction && await SessionCompaction.isOverflow({ tokens: usage, model })) {
    needsCompaction = true
  }
}
```

### Agent-Side Awareness

The key innovation: inject context state into the agent's system prompt so it
can make intelligent decisions.

```typescript
// session/system.ts — append to system prompt

function contextBudgetSection(state: ContextState): string {
  if (state.zone === "green") return ""  // silent when plenty of room

  const lines = [
    `<context-budget zone="${state.zone}">`,
    `Usage: ${state.budget.percentage}% (${fmt(state.budget.used)}/${fmt(state.budget.usable)} tokens)`,
    `Estimated turns remaining: ~${state.trend.turnsRemaining}`,
  ]

  if (state.zone === "yellow") {
    lines.push(`Tip: Use concise tool outputs. Consider summarizing research.`)
  } else if (state.zone === "orange") {
    lines.push(`Warning: Consider using /compact soon. Avoid large file reads.`)
    lines.push(`Largest consumers: ${topConsumers(state.composition)}`)
  } else if (state.zone === "red" || state.zone === "critical") {
    lines.push(`Critical: Compact immediately or risk automatic compaction.`)
    lines.push(`Suggest: /compact to preserve context control.`)
  }

  lines.push(`</context-budget>`)
  return lines.join("\n")
}
```

This means the agent naturally adapts its behavior:
- **Green**: Normal operation. No context awareness needed.
- **Yellow**: Agent starts preferring concise outputs, summarizes tool results.
- **Orange**: Agent explicitly suggests `/compact` to the user, avoids heavy operations.
- **Red**: Agent urgently recommends compaction, keeps responses minimal.
- **Critical**: System auto-compacts (existing behavior, but now the agent knows it's coming).

### Trend Analysis

The `trend` field enables predictive behavior:

```typescript
function computeTrend(recentTurns: TurnMetrics[]): Trend {
  if (recentTurns.length < 3) return { tokensPerTurn: 0, turnsRemaining: Infinity, growthRate: "stable" }

  const deltas = recentTurns.slice(1).map((t, i) => t.totalTokens - recentTurns[i].totalTokens)
  const avgDelta = deltas.reduce((a, b) => a + b, 0) / deltas.length
  const remaining = (budget.usable - budget.used) / avgDelta

  // Detect acceleration
  const recentAvg = avg(deltas.slice(-3))
  const olderAvg = avg(deltas.slice(0, -3))
  const growthRate = recentAvg > olderAvg * 1.5 ? "accelerating"
                   : recentAvg > olderAvg * 1.1 ? "growing"
                   : "stable"

  return { tokensPerTurn: Math.round(avgDelta), turnsRemaining: Math.round(remaining), growthRate }
}
```

**Accelerating growth** (many tool calls, expanding research) triggers earlier
compaction recommendations. **Stable growth** (back-and-forth conversation) lets
the session run longer before recommending action.

### Composition Breakdown

Understanding WHERE tokens are spent enables smart pruning:

```typescript
function computeComposition(msgs: MessageV2.WithParts[]): Composition {
  let systemPrompt = 0, history = 0, toolOutputs = 0, placeholders = 0

  for (const msg of msgs) {
    if (msg.info.role === "user" && msg.parts.some(p => p.type === "compaction")) {
      // System prompt estimate (first message after compaction boundary)
      continue
    }
    for (const part of msg.parts) {
      if (part.type === "tool" && part.state?.status === "completed") {
        if (part.state.time?.compacted) {
          placeholders += Token.estimate("[Old tool result content cleared]")
        } else {
          toolOutputs += Token.estimate(part.state.output)
        }
      } else if (part.type === "text") {
        history += Token.estimate(part.content)
      }
    }
  }

  return { systemPrompt, history, toolOutputs, compactedPlaceholders: placeholders }
}
```

This enables targeted recommendations:
- "Tool outputs are 60% of your context — consider compacting old tool results"
- "System prompt is 15% — consider reducing AGENTS.md"
- "History is 80% — this conversation is mostly text, compact will lose context"

### Smart Compaction Strategies

Instead of one-size-fits-all compaction, the context intelligence system can
recommend specific strategies:

```typescript
type CompactionStrategy =
  | { type: "full"; reason: "critical zone" }
  | { type: "prune-tools"; olderThan: number; reason: "tool outputs dominate" }
  | { type: "suggest-subagent"; reason: "research expanding context rapidly" }
  | { type: "suggest-compact"; reason: "approaching limit, user should decide" }
  | { type: "reduce-verbosity"; reason: "agent output too detailed for remaining budget" }
```

A plugin implementing `context.update` could return different strategies:

```typescript
"context.update": async (event) => {
  if (event.zone === "orange" && event.composition.toolOutputs > event.budget.used * 0.5) {
    // Tool outputs dominate — prune old ones instead of full compaction
    return { action: "prune", context: ["Heavy tool output detected. Pruning old results."] }
  }

  if (event.trend.growthRate === "accelerating" && event.trend.turnsRemaining < 5) {
    // Rapid growth — suggest spawning subagent for research
    return {
      context: [
        "Context growing rapidly (~" + event.trend.tokensPerTurn + " tokens/turn). " +
        "Consider spawning a subagent for remaining research to keep main context clean."
      ]
    }
  }

  if (event.zone === "red") {
    return {
      action: "compact",
      context: ["Auto-compacting: context at " + event.budget.percentage + "%."]
    }
  }

  return { action: "none" }
}
```

## Tokenizer Differences Across Models

Different models use different tokenizers. The same conversation text produces
different token counts:

| Model Family | Tokenizer | ~Tokens per 1K chars |
|-------------|-----------|---------------------|
| Claude (Anthropic) | Custom BPE | ~250-280 |
| GPT-4o (OpenAI) | o200k_base | ~230-260 |
| Gemini (Google) | SentencePiece | ~240-270 |
| DeepSeek | Custom | ~260-290 |

**Implication**: Token counts from one model's response don't directly translate
to another model's context usage. A conversation that used 140K tokens on Claude
might use 120K tokens on GPT-4o (different tokenizer efficiency).

### Pragmatic Approach: Use Provider-Reported Tokens

Rather than re-tokenizing (expensive, requires model-specific tokenizer libraries),
we use the token counts reported by the CURRENT model's API response:

```typescript
// The tokens field comes directly from the LLM API response
// Each provider reports tokens in ITS OWN tokenizer
tokens: {
  input: number,    // provider-reported input tokens
  output: number,   // provider-reported output tokens
  ...
}
```

When the model switches, the next response's `tokens.input` reflects the full
context as tokenized by the NEW model. This is the most accurate count available
without running a local tokenizer.

**The gap**: Between model switch and first response, we don't have the new model's
token count. For the pre-switch warning, we use a heuristic estimate:

```typescript
function estimateTokensOnModel(currentTokens: number,
                                currentModel: string,
                                targetModel: string): number {
  // Rough cross-model token ratio (empirically derived)
  const RATIOS: Record<string, number> = {
    "anthropic->openai": 0.92,    // Claude tokens → GPT tokens (GPT tokenizer more efficient)
    "openai->anthropic": 1.09,
    "anthropic->google": 0.95,
    "google->anthropic": 1.05,
    // ... etc
  }
  const key = `${getFamily(currentModel)}->${getFamily(targetModel)}`
  return Math.round(currentTokens * (RATIOS[key] ?? 1.0))
}
```

This is intentionally conservative (overestimates rather than underestimates).
The real count arrives on the first response from the new model.

## Integration with Dolt Storage

When the storage backend is Dolt, context awareness gains additional capabilities:

### 1. Branch-Based Token Accounting

```sql
-- How much is on trunk vs branches?
SELECT
  CASE WHEN b.name = 'main' THEN 'trunk' ELSE 'branch' END as location,
  SUM(LENGTH(JSON_EXTRACT(p.data, '$.state.output'))) as output_bytes,
  COUNT(*) as part_count
FROM part p
JOIN dolt_branches b ON ...
WHERE p.session_id = ?
GROUP BY location;
```

With the Git DAG model, trunk token count is naturally small (pointers only).
Branch data doesn't count against the context budget.

### 2. Historical Context Patterns

```sql
-- What was the typical context pattern for this type of work?
SELECT
  AVG(s.summary_tokens_after_compact) as avg_post_compact,
  AVG(s.peak_tokens) as avg_peak,
  AVG(s.turns_to_compact) as avg_turns
FROM session_summaries s
WHERE s.project_id = ?
  AND s.model LIKE 'claude%'
ORDER BY s.computed_at DESC
LIMIT 10;
```

Over time, the system learns: "For this project, sessions typically compact at
turn 15 with 180K tokens. You're at turn 12 with 160K tokens — expect compaction
in ~3 turns."

### 3. Smart Pruning with Dolt Recovery

```sql
-- Prune old tool outputs (they're preserved in Dolt history)
UPDATE part
SET data = JSON_SET(data, '$.state.output', NULL)
WHERE session_id = ?
  AND JSON_EXTRACT(data, '$.type') = 'tool'
  AND JSON_EXTRACT(data, '$.state.status') = 'completed'
  AND time_created < ?;

-- If needed later:
SELECT JSON_EXTRACT(data, '$.state.output')
FROM part AS OF 'commit_before_prune'
WHERE id = ?;
```

True pruning (not just flagging) because Dolt versioning preserves the data.

## Comparison: Prior Art vs Proposed

| Dimension | Prior art (external hook) | Proposed (context.update) |
|-----------|---------------------------|--------------------------|
| Data source | Parse full transcript JSONL | Token data from LLM response (already available) |
| Firing | 4 specific tool types only | Every LLM step finish |
| Computation | File I/O + parsing (~100ms) | In-memory computation (~1ms) |
| Threshold | 3 bands (50/75/90), fire-once | 5 zones, continuous updates |
| Recommendation | Static "Consider /compact" | Intelligent strategy (prune/subagent/reduce/compact) |
| Trend | None | Growth rate + turns remaining estimate |
| Composition | None | Per-category token breakdown |
| Agent awareness | System-reminder injection | System prompt section + hook response |
| Smart compaction | None | Plugin-driven strategy selection |
| History | None | Dolt-backed session pattern learning |

## Hook Interface Addition

Add to unified-hook-model.md's `LifecycleHooks`:

```typescript
interface LifecycleHooks {
  // ... existing 13 lifecycle events ...

  // Fires after every LLM step with current context intelligence
  "context.update"?: (event: ContextState) => Promise<{
    context?: string[]    // inject into next turn
    action?: "compact" | "prune" | "none"
  }>
}
```

This makes the total: **14 lifecycle events + 13 transform hooks = 27 hook points.**

## Implementation Priority

| Step | What | Effort | Impact |
|------|------|--------|--------|
| 1 | `ContextState` type + `computeContextState()` | Low | Foundation for everything else |
| 2 | `context.update` lifecycle event in processor.ts | Low | Fires the event |
| 3 | Zone-based system prompt injection | Medium | Agent becomes context-aware |
| 4 | Trend analysis (tokens per turn, turns remaining) | Medium | Predictive recommendations |
| 5 | Composition breakdown | Medium | Targeted pruning strategies |
| 6 | Smart compaction plugin | High | Plugin-driven compaction decisions |
| 7 | Dolt history patterns | High | Learning from past sessions |

Steps 1-3 can ship as a standalone PR. Steps 4-5 add intelligence. Steps 6-7
require the storage backend refactor.
