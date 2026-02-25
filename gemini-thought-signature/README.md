# Gemini thought_signature Research Hub

**Status**: Complete — ready for spec
**Issue**: [Kilo-Org/kilocode#6018](https://github.com/Kilo-Org/kilocode/issues/6018)
**Beads**: kc-nm7 (parent: kc-934)
**Sessions**: 1b1f7214 (planning), c4f751ae (research)

## Summary

Gemini 3.x requires `thoughtSignature` — an opaque encrypted bytes field — on
`functionCall` parts in conversation history. Missing it returns HTTP 400.

The bug is in **kilocode's message pipeline**, not the Vercel AI SDK. The SDK
handles `thoughtSignature` correctly since `@ai-sdk/google@2.0.39`. Kilocode
pins v2.0.54 (well past the fix).

## Artifacts

| File | Purpose |
|------|---------|
| `api-contract.md` | Google Gemini thoughtSignature API specification |
| `data-flow.md` | Full pipeline trace: processor → DB → message-v2 → SDK → Google |
| `sdk-version-analysis.md` | @ai-sdk/google v2.0.54 vs v3.0.31 comparison |
| `pydantic-ai-reference.md` | Pydantic AI reference implementation analysis |
| `test-matrix.md` | Test scenarios for the fix |
| `decisions.md` | Research decisions |

## Key Findings

1. **`thoughtSignature` is zero matches in kilocode source** — kilocode never
   handles it by name. The Vercel AI SDK does all extraction/injection. Kilocode's
   role is preserving the opaque `providerMetadata` blob.

2. **The `differentModel` guard at `message-v2.ts:600`** strips all
   `providerMetadata` (including the nested `thoughtSignature`) when the current
   model doesn't match the stored model. This is correct for cross-provider
   switches but may fire unexpectedly for Gemini.

3. **`@ai-sdk/google@2.0.54` already handles `thoughtSignature`** — emits it in
   `providerMetadata` on streaming events, extracts it from `providerOptions`
   when building requests. The bug is in kilocode's preservation, not the SDK.

4. **v3.0.31 has two additional fixes** not in v2.0.54: dynamic `providerOptionsName`
   for Vertex (v3.0.23), and empty-text part handling (v3.0.24). Only the Vertex
   fix is potentially relevant.

## Root Cause Hypotheses

| # | Hypothesis | Evidence |
|---|-----------|----------|
| A | `differentModel` evaluates `true` unexpectedly for same-model Gemini sessions | Model ID comparison at message-v2.ts:600. Needs runtime verification |
| B | `tool-input-start` creates ToolPart without metadata, `tool-call` overwrites but may lose timing | processor.ts:113 vs 136. No metadata on initial creation |
| C | Model ID stored at creation time differs from model ID at replay time (registry refresh, preview rename) | Provider.getModel resolves from models.dev — IDs could shift |

## References

- [Google Thought Signatures docs](https://ai.google.dev/gemini-api/docs/thought-signatures)
- [Vercel AI SDK #12351](https://github.com/vercel/ai/issues/12351) — vertex namespace desync
- [Vercel AI SDK #10560](https://github.com/vercel/ai/issues/10560) — streamText swallows providerMetadata
- Pydantic AI `pydantic_ai/models/google.py` — reference round-trip implementation
