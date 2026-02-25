# Pydantic AI Reference Implementation

**Repo**: pydantic/pydantic-ai
**Clone**: /Volumes/atlas/pydantic-ai

## Architecture

Pydantic AI has two Gemini implementations:
- `google.py` — Current, SDK-based (`google-genai` Python SDK). Full round-trip.
- `gemini.py` — Deprecated, REST-based. Broken round-trip.

Pydantic AI does NOT use Vercel AI SDK. It has its own Google API client layer.

## Round-Trip Implementation (google.py)

### Receive (response -> internal)

```python
# google.py:904-910
if part.thought_signature:
    thought_signature = base64.b64encode(part.thought_signature).decode('utf-8')
    provider_details = {'thought_signature': thought_signature}
```

Stored in `ToolCallPart.provider_details` or `ThinkingPart.provider_details`.

### Forward-Attach Pattern

Signature from `ThinkingPart` attaches to the **NEXT** part, not in-place:

```python
# google.py:1096-1099
elif isinstance(item, ThinkingPart):
    if item.provider_name == provider_name and item.signature:
        thinking_part_signature = item.signature
```

Then on the next part:
```python
elif thinking_part_signature:
    part['thought_signature'] = base64.b64decode(thinking_part_signature)
```

### Send Back (internal -> request)

```python
# google.py:1067-1091
if (item.provider_details
    and (thought_signature := item.provider_details.get('thought_signature'))
    and (m.provider_name == provider_name or item.provider_name == provider_name)):
    part['thought_signature'] = base64.b64decode(thought_signature)
elif thinking_part_signature:
    part['thought_signature'] = base64.b64decode(thinking_part_signature)
```

### Fallback Sentinel

```python
if function_call_requires_signature and not part.get('thought_signature'):
    part['thought_signature'] = b'skip_thought_signature_validator'
```

### Namespace Isolation

Provider name guard prevents cross-contamination:
- `google-gla` — Google AI (generativelanguage.googleapis.com)
- `google-vertex` — Vertex AI

## Relevance to Kilocode Fix

Pydantic AI is a **conceptual reference**, not a code template:

| Pydantic AI | Kilocode |
|-------------|----------|
| Own HTTP client | Vercel AI SDK |
| Explicit `thought_signature` handling | Opaque `providerMetadata` blob |
| `provider_details` dict | `part.metadata` record |
| Forward-attach pattern | SDK handles internally |

The key insight from Pydantic AI: signatures must survive the full round-trip
and the SDK (or app) must never drop them during message reconstruction.

## Deprecated gemini.py — Cautionary Example

The deprecated REST implementation parses `thoughtSignature` but does NOT
round-trip it. `ThinkingPart` is dropped on the way back out:

```python
# gemini.py:662-666
elif isinstance(item, ThinkingPart):
    # NOTE: We don't send ThinkingPart to the providers yet.
    pass
```

This is exactly the class of bug kilocode has — the metadata is captured but
lost during message reconstruction.
