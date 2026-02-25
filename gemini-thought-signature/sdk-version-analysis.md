# @ai-sdk/google Version Analysis

**Pinned**: 2.0.54 | **Latest**: 3.0.31

## thoughtSignature Timeline

| Version | Change | Commit |
|---------|--------|--------|
| 2.0.39 | `preserve thoughtSignature through tool execution` | c89268c |
| 2.0.54 | **(pinned)** — includes all v2 fixes | — |
| 3.0.0-beta.51 | Same fix ported to v3 | 8370068 |
| 3.0.0-beta.90 | Dynamic `providerOptionsName` for Vertex | 218bba1 |
| 3.0.23 | Dynamic `providerOptionsName` (stable) | 218bba1 |
| 3.0.24 | Handle `thoughtSignature` on empty-text parts | 3b3e32f |
| 3.0.31 | **(latest)** | — |

## v2.0.54 Capabilities (What Kilocode Has)

- Emits `thoughtSignature` in `providerMetadata: { google: { thoughtSignature } }` on streaming events
- Extracts from `part.providerOptions.google.thoughtSignature` (hardcoded `google` key)
- Attaches to `functionCall`, `text`, and reasoning parts in Gemini API payload
- 20 references to `thoughtSignature` in compiled output

## v3.0.31 Additional Fixes (What Kilocode Lacks)

### 1. Dynamic providerOptionsName (v3.0.23)

```javascript
// v2.0.54 — hardcoded
part.providerOptions?.google?.thoughtSignature

// v3.0.31 — dynamic
const providerOpts =
  part.providerOptions?.[providerOptionsName] ??
  (providerOptionsName !== 'google' ? part.providerOptions?.google : undefined)
```

**Impact**: Only matters for `@ai-sdk/google-vertex` provider. The GH#6018
reporter uses Google direct, not Vertex. However, kilocode pins
`@ai-sdk/google-vertex@3.0.106` which may have this fix already.

### 2. Empty-text part handling (v3.0.24)

Handles `thoughtSignature` on parts where `text` is empty during streaming.
Edge case that could cause signature loss during streaming.

## Recommendation

The pinned v2.0.54 is sufficient for the GH#6018 fix. The bug is in kilocode's
metadata preservation, not the SDK. A version bump to v3.0.31 could be a
follow-up improvement (especially for Vertex users) but is not required.

## Key Difference: v2 vs v3

v2 uses hardcoded `'google'` key for providerOptions lookup. This means:
- Google direct provider: Works (key is `google`)
- Google Vertex provider: **Broken** in v2 (key is `vertex`, but lookup uses `google`)

v3 dynamically resolves the key. This is the "Gap 2" from the original design
notes, but it only affects Vertex users and requires a major version bump.
