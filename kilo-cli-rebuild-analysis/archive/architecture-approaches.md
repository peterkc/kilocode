# Architecture Approaches

Four approaches evaluated for rebuilding the Kilo Code CLI.

## Approach 1: Improve in Place (TypeScript/Ink)

**Effort**: Low (1-2 months)
**Description**: Optimize the current TypeScript CLI without rewriting.

Potential improvements:
- Lazy-load heavy deps (puppeteer, xlsx, mammoth) to cut cold start
- Replace Ink with a lighter terminal renderer (e.g., blessed-contrib or raw ANSI)
- Tree-shake unused providers at build time
- Bundle into a single JS file with embedded deps (like Claude Code does)
- Use V8 snapshots for faster Node.js startup

Pros:
- Lowest risk, preserves existing test suite
- Team stays productive on features instead of infrastructure
- Full shared-code benefit with VSCode extension

Cons:
- Still requires Node.js runtime
- Memory floor remains ~100MB+ due to V8 heap
- Cannot escape 139-dependency supply chain
- TUI capabilities limited by Ink's React model

**When to choose**: When developer UX is "good enough" and feature velocity matters more.

## Approach 2: Go TUI + Node.js Engine (Hybrid lazygit Model)

**Effort**: Medium (3-6 months)
**Description**: Build a native Go TUI that communicates with the existing Node.js agent engine over JSON-stdio IPC.

```
User
  |
  v
Go Binary (Bubbletea TUI)           # ~50ms startup
  ├── Panels: Chat | Diff | Terminal | Context
  ├── Vim keybindings
  ├── Markdown rendering (Glamour)
  └── JSON-stdio IPC
        |
        v
Node.js Engine Process               # Spawned on first agent action
  ├── packages/agent-runtime/
  ├── src/ (341K LoC shared core)
  └── packages/vscode-shim/
```

The Go binary is what the user installs and sees. The Node.js engine is an implementation detail, bundled inside the binary or downloaded on first run.

Pros:
- Instant startup (Go binary renders UI immediately, engine loads async)
- Single binary distribution (embed Node.js engine or fetch on first use)
- Bubbletea panel layout (lazygit-quality UX)
- Vim keybindings (developer-native)
- Preserves all 56 providers and 25+ tools without rewriting
- IPC boundary enables independent evolution of TUI and engine

Cons:
- Two-process architecture adds IPC complexity
- Need to define and maintain the IPC protocol
- Engine still uses ~150MB (but user doesn't see it)
- Two codebases to maintain (Go TUI + TS engine)

**Precedents**:
- Neovim: C core + Lua/Python/Node.js plugins over msgpack-rpc
- LSP: Editor TUI + Language Server over JSON-RPC
- Claude Code: TypeScript CLI + API over HTTP

**When to choose**: When startup time, distribution, and TUI quality matter, but you can't afford to rewrite the engine.

## Approach 3: Full Native Rewrite (Go or Rust)

**Effort**: Very High (1-2 years, team of 3-5)
**Description**: Rewrite the entire agent engine and TUI in Go or Rust.

What you'd need to rewrite:
- [ ] 56 LLM provider integrations (streaming, auth, rate limiting)
- [ ] 25+ tool implementations (file ops, shell exec, browser, MCP)
- [ ] Context window management and token budgeting
- [ ] Conversation condensation
- [ ] Task orchestration and subagent delegation
- [ ] System prompt generation and mode management
- [ ] Git-based checkpoints (undo/redo)
- [ ] MCP client and server
- [ ] Session persistence and history
- [ ] Custom modes and slash commands
- [ ] Telemetry and analytics
- [ ] Tree-sitter code analysis
- [ ] Document parsing (PDF, XLSX, DOCX)
- [ ] i18n (20+ languages)

Pros:
- Minimal memory (~20MB Go, ~10MB Rust)
- Fastest possible startup
- Single language, single binary, zero dependencies
- Full control over every abstraction
- No VSCode shim baggage

Cons:
- 1-2 year rewrite during which competitors ship features
- Must maintain parity with 56 providers that each have quirks
- LLM SDK ecosystem in Go/Rust lags TypeScript
- Risk of second-system syndrome (over-engineering the rewrite)
- Team needs deep Go/Rust expertise

**When to choose**: Only if starting a new product from scratch. Not viable for an existing product with 1.5M users.

## Approach 4: Ghostty-Based Terminal Embedding

**Effort**: Very High + Zig expertise
**Description**: Use Ghostty's terminal rendering as the foundation, building an AI-native terminal emulator.

```
Ghostty (libghostty — Zig)
  ├── GPU-accelerated rendering
  ├── Native terminal emulation (VT100+)
  └── Custom UI overlays
        |
        v
Kilo Agent Layer
  ├── AI chat panel (overlay)
  ├── Tool execution (native PTY)
  ├── Diff viewer (GPU-rendered)
  └── LLM streaming
```

Pros:
- GPU-accelerated rendering (smoothest possible UI)
- Native terminal emulation (no PTY shims)
- Could render rich UI elements (diffs, images, charts)
- Unique market position (AI-native terminal, not AI in terminal)

Cons:
- Ghostty has no stable plugin/embedding API
- Zig is a niche language (hiring, ecosystem)
- Zig <-> Node.js FFI is unusual and poorly documented
- Converges on Warp's territory (funded, shipping, 5M+ users)
- Building a terminal emulator is a multi-year effort in itself
- Ghostty is Mitchell Hashimoto's passion project — no guarantee of enterprise support

**Warp comparison**:

| | Warp | Ghostty-based Kilo |
|---|------|---------------------|
| Core identity | Terminal with AI | AI agent with terminal |
| Rendering | Custom Rust GPU | Ghostty Zig GPU |
| AI integration | Copilot-style assist | Full agentic (tools, context, subagents) |
| Business model | SaaS (Warp Drive) | Model-agnostic (500+ models) |
| Maturity | Production, 5M+ users | Hypothetical |

**When to choose**: Only if building a new terminal product from scratch with a team that has Zig expertise, and Ghostty ships a stable embedding API.

## Approach 5: Bun + OpenTUI + Membrane (Recommended)

**Effort**: Medium (3-4 months)
**Description**: Migrate runtime from Node.js to Bun, replace Ink with OpenTUI (Zig core + React reconciler), and replace the VSCode shim with a minimal membrane interface.

```
User
  |
  v
Bun runtime (~200ms startup)
  ├── Commander (arg parsing, unchanged)
  ├── Jotai atoms (state management, unchanged)
  ├── OpenTUI (Zig core via bun:ffi)
  │   ├── React reconciler (same JSX components)
  │   ├── Zig double-buffered cell diff
  │   ├── NativeSpanFeed (zero-copy LLM streaming)
  │   └── Terminal capability detection
  ├── KiloRuntime membrane (~200 lines)
  │   ├── BunFileSystem (replaces workspace.fs shim)
  │   ├── FileBackedConfig (replaces getConfiguration shim)
  │   └── DirectMessageBus (replaces webview postMessage shim)
  └── Engine (341K LoC, unchanged)
      ├── 56 LLM providers
      ├── 25+ tools
      └── Context/prompts/task orchestration
```

Pros:
- Same language (TypeScript) — no IPC, no two-codebase maintenance
- Same React component model — incremental migration, not rewrite
- 75x faster LLM streaming (NativeSpanFeed, per OpenCode benchmarks)
- All 56 providers preserved unchanged
- Bun compile -> single binary distribution
- Shim drops from 1,500 lines to ~200 lines
- Proven at scale (OpenCode, 110K stars)

Cons:
- Bun is less mature than Node.js (some native addons may not work)
- OpenTUI requires Zig installed for development builds
- Bun compile binaries are larger (~80MB vs ~15MB Go)
- Startup is ~200ms (vs ~50ms Go native)

**Precedent**: OpenCode (anomalyco/opencode) uses exactly this stack in production.

**When to choose**: When you own the codebase, want to preserve the TypeScript engine and React components, and need dramatically better streaming performance without a language rewrite.

See `migration-plan.md` for the four-phase implementation plan.
