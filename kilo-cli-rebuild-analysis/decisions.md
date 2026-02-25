# Design Decisions Log

Captures decisions made during the Kilo CLI rebuild analysis session.

## D1: Engine is the Expensive Part

**Decision**: Any rebuild strategy must preserve or incrementally migrate the 341K-line agent engine.
**Rationale**: The engine contains 56 LLM provider integrations, each with streaming quirks, auth flows, and rate limiting. This is 85% of the value and cannot be rewritten in less than 1-2 years.
**Status**: Stands.

## D2: Go Over Rust for Native Rebuild

**Decision**: If forced to choose a native language, Go is more pragmatic than Rust.
**Rationale**: Bubbletea ecosystem, goroutines, fast iteration, larger talent pool.
**Trade-off**: Rust is technically superior (memory, startup, safety).
**Status**: Stands, but deprioritized by D8.

## D3: Hybrid Architecture (Original Recommendation)

**Decision**: Go TUI + Node.js engine over JSON-stdio IPC.
**Rationale**: Preserves all 56 providers without rewriting. IPC boundary is well-understood.
**Status**: **Superseded by D8.** Bun + OpenTUI eliminates the need for two languages and IPC.

## D4: Ghostty Approach is Premature

**Decision**: Do not build on Ghostty today.
**Rationale**: No plugin/embedding API, Zig expertise is rare, converges on Warp's territory.
**Status**: Stands.

## D5: lazygit is the Right UX Inspiration

**Decision**: Panel-based TUI model is the gold standard for developer tools.
**Caveat**: AI agent surface area is larger than git's. TUI must be more dynamic.
**Status**: Stands.

## D6: 56-Provider Rewrite is a False Constraint

**Decision**: Go's ecosystem can cover ~80% of providers via gateway + OpenAI-compatible pattern.
**Rationale**: Bifrost (Go gateway, 15+ direct + 1000+ via routing), langchaingo (13 providers), maruel/genai (19 providers). Most "providers" are OpenAI-compatible with different base URLs.
**Status**: New. Weakens the argument that Go can't match TypeScript's provider coverage.

## D7: VSCode Shim Bottleneck is the Webview Message Bus

**Decision**: The shim's essential purpose is providing a fake webview postMessage channel for engine orchestration. Everything else is either trivial file ops or no-ops.
**Rationale**: 251 files import vscode, but only ~200 lines of actual behavior matter. The remaining ~1,300 lines are stubs. A membrane interface replaces the shim.
**Status**: New.

## D8: Bun + OpenTUI is the Recommended Path

**Decision**: For a team that owns the Kilo codebase, Bun + OpenTUI supersedes the Go hybrid.
**Rationale**:
- Same language (TypeScript) — no IPC protocol, no two-codebase maintenance
- Same React component model — incremental migration, not a rewrite
- OpenTUI's Zig core gives near-native rendering (75x faster LLM streaming)
- Bun's bun:ffi provides zero-overhead calls to the Zig core
- All 56 providers preserved unchanged (engine stays TypeScript)
- Bun compile produces single binary distribution
**Trade-off**: Go hybrid still wins on raw startup (~50ms vs ~200ms) and binary size (~15MB vs ~80MB). Neither justifies the architectural complexity.
**Status**: **New. Supersedes D3.**

## D9: Membrane Interface Over Full Shim

**Decision**: Replace the 1,500-line VSCode shim with a ~200-line KiloRuntime membrane.
**Rationale**: The engine needs file ops, config, message bus, identity, and value types. Everything else is no-ops. Dependency injection replaces require.cache monkey-patching.
**Status**: New.

## D10: Bun Runtime Enables Zero-Overhead Zig FFI

**Decision**: Migrating to Bun as runtime (not just build tool) is required for OpenTUI.
**Rationale**: OpenTUI uses bun:ffi (dlopen) to call the Zig shared library. This is Bun-specific and does not work on Node.js. The FFI overhead is microseconds because both Bun and OpenTUI are Zig underneath.
**Implication**: Phase 1 of migration must validate all 139 dependencies under Bun before proceeding.
**Status**: New.

## D11: Separate Tools Over Overloaded Search

**Decision**: Create `code_grep` and `code_inspect` as new tools rather than modifying `codebase_search`.
**Rationale**:
- LLMs pick tools based on their description — separate tools with clear intent produce better tool selection
- Each tool has a distinct backend: ripgrep (grep), ckd/Dolt (inspect), embeddings (semantic)
- Default path (grep + inspect) requires zero external API keys
- Matches how developers actually search: grep for strings, jump-to-definition, check git blame, then conceptual search
- Claude Code validates this pattern: Grep, Glob, and Task(Explore) are separate tools
**Implication**: Three-tool search hierarchy. See `tool-design.md` for specifications.
**Status**: New. Tracked in acf-uabi2.

## D12: ckd/Dolt for AHP Memory Protocol

**Decision**: Build the AHP memory protocol on ckd/Dolt, not flat markdown files.
**Rationale**:
- SQL-queryable memory vs grep through markdown
- Versioned with dolt diff/log — see how memory evolved over time
- Confidence scoring with decay — stale knowledge fades, recent corrections surface
- Cross-project knowledge via scope levels (project, user, global)
- Team sharing via dolt push/pull with row-level 3-way merge
- Corrections table tracks learning trajectory (what was wrong → right → why)
- Semantic search via ckd embeddings (when ready)
- Session handoff via structured session_context table
**Bootstrap**: Memory is ckd's first production consumer — validates the platform before code_inspect ships. Stone Soup: start small (memory tables), prove value, then expand (AST search).
**Fallback**: Flat files (`.agents/memory/*.md`) for AHP-Core compliance without ckd.
**Status**: New. Tracked in acf-qv7wn.

## D15: Native Skills (Binary/WASM/Service) for AHP

**Decision**: AHP skills can be packaged as compiled binaries, WASM modules, or persistent services — not only markdown+scripts.
**Rationale**:
- **Context efficiency**: Native skills consume ~50 tokens (manifest) vs ~3000 tokens (markdown SKILL.md + resources). 60x savings
- **Language-agnostic**: Skills can be written in Go, Rust, Zig, Python — any language that speaks JSON-RPC over stdio
- **Distributable**: Binary/WASM skills can be published to a registry, installed with `ax skills install`
- **Sandboxed**: WASM skills run in-process with memory sandboxing
- **Model-independent**: Binary handles workflow logic. Only explicit `llm_call` yields consume LLM tokens
**Protocol**: Coroutine model over JSON-RPC 2.0. Skill yields (tool_call, ask_user, spawn_subagent, llm_call), runtime resumes with results.
**Distribution tiers**: Community (markdown, git), Official (WASM, registry), Enterprise (binary/service, commercial)
**Status**: New. Tracked in acf-ycviq.

## D16: AHP Skills Compose With MCP, Don't Replace It

**Decision**: Native AHP skills and MCP tools are complementary, not competing.
**Rationale**:
- MCP = stateless external tool access (single request/response). Scope: databases, APIs, cloud services
- AHP skills = stateful workflow orchestration (coroutine lifecycle). Scope: compound workflows
- Skills CALL MCP tools via yield: tool_call("UseMcpTool", {server, tool, args})
- Same transport (JSON-RPC over stdio) — could converge as an MCP extension
**Implication**: A runtime implements both MCP (tools) and AHP skills (workflows). They compose.
**Status**: New.

## D17: Purpose-Routed LLM Calls in Skill Protocol

**Decision**: Skills declare the purpose/tier of each LLM call (`classification`, `extraction`, `analysis`, `generation`, `reasoning`). The runtime maps purpose to the best available model.
**Rationale**:
- Skills declare intent, not model names — portable across user configurations
- Local models handle cheap ops (classification, extraction) — free, fast, private
- Cloud models handle quality ops (generation, reasoning) — reliable, high quality
- Runtime manages all LLM connections — skills never embed their own LLM clients
- Purpose taxonomy enables per-tier cost optimization (45-50% savings vs single-model)
- Privacy-aware: `require_local: true` keeps source code off cloud for cheap ops
**Protocol**: `yield: llm_call(purpose, prompt, max_tokens)` → runtime routes → `resume(result, metadata)`
**Metadata includes**: model, provider, latency_ms, tokens_in, tokens_out, cost — skill can adapt strategy
**Status**: New. Extension to acf-ycviq (native skills).

## D18: Local LLMs for Cheap Ops, Cloud for Quality

**Decision**: The default purpose-routing maps classification+extraction to local models and generation+reasoning to cloud models.
**Rationale**:
- A local 3B model classifying "bug fix or feature?" at 50ms is strictly better than a cloud round-trip at 500ms+
- Classification and extraction see raw code — local keeps code private
- Generation and reasoning see summaries/intent — cloud is safe
- Kilo's 56 providers are the cloud tier. Local LLM connections (LM Studio, Ollama, Docker Model Runner) are the local tier
- Configuration via `.agents/models.json` — user controls routing
**Trade-off**: Requires local LLM server running for maximum savings. Without local, everything falls back to cloud (still works, just costs more).
**Status**: New.

## D13: bdx/Dolt for AHP Work Protocol

**Decision**: Build the AHP work protocol on bdx/Dolt, replacing ephemeral session-only todo lists.
**Rationale**:
- Persistent work items survive sessions (todos don't)
- Dependency graph (DAG) enables blocked/ready semantics
- Structured handoff replaces lossy conversation-restore
- Append-only notes preserve session history per work item
- SQL-queryable work state (vs grep through markdown)
- Team sharing via dolt push/pull
**What it replaces in Claude Code**: TaskCreate/TaskList (ephemeral), `--continue` (conversation restore), gold layer summaries (lossy)
**Status**: New. Tracked in acf-zqxv6.

## D14: Memory = What We Learned, Work = What We're Doing

**Decision**: ckd (memory) and bdx (work) are separate concerns, both Dolt-backed.
**Rationale**:
- Memory entries have confidence scores, decay, corrections — knowledge lifecycle
- Work items have status, dependencies, blocking — task lifecycle
- Different query patterns: "what do I know about X?" vs "what's blocked?"
- Composable handoff: `handoff()` queries both for a unified session context
- Can share a Dolt instance or be separate — membrane abstracts this
**Status**: New.

## D19: Kilo Already Built the Rewrite

**Decision**: The `Kilo-Org/kilo` repo is a ground-up rewrite — our D8 recommendation was independently validated.
**Rationale**:
- Fork of opencode with `kilocode_change` markers for upstream sync
- 265K LoC (70% reduction from 895K legacy)
- Bun native runtime, Hono HTTP server, Vercel AI SDK
- SolidJS for app/desktop/webview, Ink kept for terminal TUI
- VSCode extension is thin client -> HTTP/SSE (no shim needed)
- Auto-generated SDK from OpenAPI spec
**Impact**: Our migration plan (D8 Phase 1-4) is moot. The work is done. Focus shifts to contribution opportunities.
**Status**: Major finding. Reframes all prior recommendations.

## D20: CLI-as-Backend Architecture

**Decision**: The new Kilo uses HTTP/SSE server (port 4096) as the backend for all frontends.
**Rationale**:
- Clean separation: CLI owns agent logic, frontends own UI
- Multi-surface: VSCode, Tauri desktop, web, Zed (ACP) — all share one backend
- Auto-generated SDK propagates API changes automatically
- OpenAPI spec enables third-party integrations
**Contrast**: Our D9 proposed a ~200-line membrane. Kilo went further: full HTTP API eliminates the shim entirely.
**Status**: Learned from new repo.

## D21: SolidJS Over React for New UI Surfaces

**Decision**: Kilo chose SolidJS for app/desktop/webview while keeping Ink (React) for terminal TUI.
**Rationale**:
- SolidJS signals are built-in reactivity (no Jotai/Zustand needed)
- Fine-grained updates (no virtual DOM diffing) — better for streaming LLM output
- Kobalte (SolidJS component library) provides accessible UI primitives
- Ink stays for terminal because it works and OpenTUI integration isn't complete yet
**Status**: Learned from new repo.

## D22: Vercel AI SDK Unifies Provider Abstraction

**Decision**: One SDK (`ai` package) replaces 15+ individual provider SDK packages.
**Rationale**:
- Single `streamText`/`generateText` API across all providers
- Provider-specific SDKs (`@ai-sdk/anthropic`, `@ai-sdk/openai`, etc.) are adapters
- Cost accounting and token tracking built in
- OTel span export built in
- Dynamic provider installation via Bun at runtime
**Contrast**: Our D6 proposed Bifrost gateway. AI SDK is the better abstraction — works at the SDK level, not the network level.
**Status**: Learned from new repo.
