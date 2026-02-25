# thoughtSignature Data Flow in Kilocode

## Full Pipeline Trace

```
@ai-sdk/google streams tool-call event
  -> providerMetadata: { google: { thoughtSignature: "<base64>" } }

processor.ts:149
  case "tool-call":
    metadata: value.providerMetadata
  -> ToolPart.metadata = { google: { thoughtSignature: "<base64>" } }

  (also: processor.ts:77 reasoning-start, :87 reasoning-delta, :107 reasoning-end,
         :320 text-start, :328 text-delta)

DB (SQLite via Drizzle)
  -> part stored with metadata field

message-v2.ts:659
  toModelMessages() builds UIMessage:
    ...(differentModel ? {} : { callProviderMetadata: part.metadata })
  -> UIMessage part: { callProviderMetadata: { google: { thoughtSignature: "..." } } }
     OR {} if differentModel === true

vercel/ai: convert-to-model-messages.ts
  callProviderMetadata != null
    ? { providerOptions: callProviderMetadata }
    : {}
  -> LanguageModelV3ToolCallPart: { providerOptions: { google: { thoughtSignature: "..." } } }

@ai-sdk/google: convert-to-google-generative-ai-messages.ts
  part.providerOptions?.google?.thoughtSignature  (v2.0.54, hardcoded 'google')
  providerOpts?.thoughtSignature                  (v3.0.31, dynamic providerOptionsName)
  -> Gemini API payload: { functionCall: { name, args }, thoughtSignature: "..." }
```

## The differentModel Guard

```typescript
// message-v2.ts:600
const differentModel =
  `${model.providerID}/${model.id}` !== `${msg.info.providerID}/${msg.info.modelID}`
```

When `true`, ALL providerMetadata is stripped from:
- Text parts (line 622)
- Tool-call completed parts (line 659)
- Tool-call error parts (line 669)
- Tool-call pending parts (line 680)
- Reasoning parts (line 687)

### When differentModel fires for Gemini

| Scenario | Fires? | Impact |
|----------|--------|--------|
| Same model, same session | No | Metadata preserved (correct) |
| User switches model mid-conversation | Yes | Correct — cross-provider metadata invalid |
| Title agent uses getSmallModel | Yes | Title-gen only, not main loop |
| Compaction agent with different model | Yes | Compacted messages lose signature |
| Subtask with agent model override | Yes | Subtask messages lose signature |
| Preview model renamed (GA release) | Yes | Old messages have old model ID |
| Provider-to-Kilo routing switch | Yes | providerID changes |

## Metadata Capture Gap

`processor.ts:113-127` — `tool-input-start` creates initial ToolPart with
**no metadata field**:

```typescript
case "tool-input-start":
  const part = await Session.updatePart({
    id: toolcalls[value.id]?.id ?? Identifier.ascending("part"),
    messageID: input.assistantMessage.id,
    sessionID: input.assistantMessage.sessionID,
    type: "tool",
    tool: value.toolName,
    callID: value.id,
    state: { status: "pending", input: {}, raw: "" },
    // NOTE: no metadata field here
  })
```

Then at `tool-call` (line 136-150), the entire part is overwritten with
`metadata: value.providerMetadata`. If the SDK emits `thoughtSignature` on
`tool-input-start` but not on `tool-call`, it would be lost.

## No Fallback

If `callProviderMetadata` is absent (differentModel=true or metadata lost),
the AI SDK has no fallback. The signature is simply missing from the Gemini
API request, and Google returns 400.
