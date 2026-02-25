# Research Decisions

## D1: Bug is in kilocode, not the SDK

**Status**: Confirmed

`@ai-sdk/google@2.0.54` handles `thoughtSignature` correctly since v2.0.39.
The SDK emits it in `providerMetadata` on streaming events and extracts it from
`providerOptions` when building Gemini requests. Zero `thoughtSignature` string
matches in kilocode source confirms kilocode never handles it by name.

## D2: differentModel guard is the primary suspect

**Status**: Hypothesis — needs runtime verification

The guard at `message-v2.ts:600` strips all `providerMetadata` when models
don't match. This is correct behavior for cross-provider switches, but may
fire unexpectedly for Gemini sessions due to model ID comparison edge cases.

However, if GH#6018 fails on "any prompt" (first turn, no switching), then
`differentModel` would be `false` and this isn't the root cause.

## D3: SDK version bump not required for primary fix

**Status**: Decided

v2.0.54 has all necessary `thoughtSignature` support. v3.0.31 adds Vertex
namespace fix and empty-text handling — nice-to-have, not required. Major
version bump (2.x -> 3.x) carries risk and is out of scope for a bug fix PR.

## D4: Pydantic AI is conceptual reference only

**Status**: Decided

Different architecture (own HTTP client vs Vercel AI SDK). The contract
(opaque round-trip, forward-attach pattern) is the useful insight, not the
code structure.

## D5: One tracer bullet, not two

**Status**: Decided

Original plan had TB1 (diagnostic) + TB2 (fix). Since we confirmed the SDK
works correctly, TB1 diagnostic collapses into the fix phase. The remaining
unknown (why `differentModel` evaluates unexpectedly OR what else drops
metadata) can be answered by a focused test + code read in Phase 1 of the spec.

## D6: Branch from upstream/main

**Status**: Decided

Base: `upstream/main` (ea40081a5). Fork's `origin/main` has divergent commits.
Per contribution rules.

## D7: Post analysis on GH#6018 before PR

**Status**: Planned

Post root cause analysis as a comment on the upstream issue before filing PR.
Demonstrates diagnostic rigor and gives maintainers context.
