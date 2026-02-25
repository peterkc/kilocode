# Test Matrix

## Framework

- **Runner**: `bun:test`
- **Target files**: `packages/opencode/test/session/message-v2.test.ts`, `packages/opencode/test/provider/transform.test.ts`
- **Existing helpers**: `assistantInfo()` with `meta` override, `createMockModel` for Gemini
- **Existing related test**: Line 358 — "omits provider metadata when assistant model differs"

## Scenarios

| # | Scenario | Model | differentModel | Expected | File |
|---|----------|-------|---------------|----------|------|
| 1 | Same-model tool call | `google/gemini-3.1-pro-preview` | `false` | `callProviderMetadata` preserved with `thoughtSignature` | message-v2.test.ts |
| 2 | Same-model reasoning part | `google/gemini-3.1-pro-preview` | `false` | `providerMetadata` preserved | message-v2.test.ts |
| 3 | Same-model text part | `google/gemini-3.1-pro-preview` | `false` | `providerMetadata` preserved | message-v2.test.ts |
| 4 | Model switch (Gemini -> Claude) | `anthropic/claude-sonnet` | `true` | metadata dropped (correct) | message-v2.test.ts (exists) |
| 5 | Sequential tool calls | `google/gemini-3.1-pro-preview` | `false` | Each call preserves its own signature | message-v2.test.ts |
| 6 | `tool-input-start` -> `tool-call` event sequence | n/a (processor) | n/a | `metadata` set on final ToolPart | processor test or new |
| 7 | Vertex namespace (`vertex` vs `google` key) | `google-vertex/gemini-*` | `false` | Signature survives transform.ts re-keying | transform.test.ts |
| 8 | Error/pending tool parts | `google/gemini-3.1-pro-preview` | `false` | `callProviderMetadata` preserved on error parts | message-v2.test.ts |

## Priority

- **Core** (must have): Rows 1, 2, 5
- **Regression** (existing behavior): Row 4
- **Edge cases** (nice to have): Rows 3, 6, 7, 8

## Mock Structures

### Gemini model fixture

```typescript
const geminiModel = {
  id: "gemini-3.1-pro-preview",
  providerID: "google",
  api: { id: "gemini-3.1-pro-preview", npm: "@ai-sdk/google" },
  // ... capabilities, cost, limit
} as Provider.Model
```

### Reasoning part with thoughtSignature

```typescript
{
  ...basePart(assistantID, "r1"),
  type: "reasoning",
  text: "thinking...",
  time: { start: 0, end: 1 },
  metadata: { google: { thoughtSignature: "abc123==" } },
}
```

### Tool part with thoughtSignature

```typescript
{
  ...basePart(assistantID, "t1"),
  type: "tool",
  tool: "read_file",
  callID: "call-1",
  state: { status: "completed", input: { path: "/foo" }, output: "content", time: { start: 0, end: 1 } },
  metadata: { google: { thoughtSignature: "xyz789==" } },
}
```
