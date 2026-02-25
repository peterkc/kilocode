# Native Skills Design: AHP Skill Protocol

**Beads**: acf-ycviq
**Related**: `tool-design.md` (tools are deterministic), this doc (skills are workflows)

## Problem

ACF skills today are markdown files the LLM reads and follows. This works but has limits:

- **Model-dependent**: Different LLMs follow the same markdown differently
- **Slow**: Loading 500+ tokens of skill protocol into context per invocation
- **Not distributable**: Can't package a skill as a binary and share it
- **Language-locked**: Skills must be TypeScript/Python scripts when deterministic logic is needed
- **Not sandboxed**: Scripts have full filesystem access

## Solution: Multi-Format Skill Protocol

Skills can be markdown (current), scripts, compiled binaries, WASM modules, or services.

### Packaging Formats

| Format | Distribution | Execution | Cold Start | Sandbox | Best For |
|--------|-------------|-----------|-----------|---------|----------|
| markdown | Git / npm | LLM reads + follows | N/A (context load) | None | Knowledge, behavioral patterns |
| script | Git / npm | `bun run` / `python` | ~100ms | Process isolation | Validation, scoring |
| binary | npm / brew / releases | Subprocess (stdio) | ~20ms | Process isolation | Performance-critical, any language |
| wasm | npm / registry | In-process (Bun WASM) | ~5ms | Memory-sandboxed | Portable, secure, fast |
| service | Docker / systemd | HTTP/gRPC (persistent) | 0ms (warm) | Network isolation | Stateful, shared, multi-user |

### Skill Directory Structure

```
.agents/skills/{name}/
├── SKILL.md              ← Always present. Metadata + description
├── skill.json            ← Runtime config (type, capabilities, binary path)
├── resources/            ← Markdown resources (for markdown/hybrid skills)
├── scripts/              ← Script helpers (for hybrid skills)
├── bin/                  ← Platform binaries (for binary skills)
│   ├── {name}-darwin-arm64
│   ├── {name}-darwin-x64
│   ├── {name}-linux-x64
│   └── {name}-linux-arm64
└── {name}.wasm           ← WASM module (for wasm skills)
```

### skill.json Specification

```json
{
    "name": "commit",
    "version": "1.0.0",
    "type": "binary",
    "trigger": "/commit",
    "description": "Generate conventional commit messages",
    "bin": "bin/commit-${platform}-${arch}",
    "protocol": "stdio-jsonrpc",
    "capabilities": {
        "tools_needed": ["Shell", "FileRead"],
        "subagents": true,
        "user_interaction": true,
        "models_needed": ["code"],
        "parallel_workers": 0
    },
    "permissions": {
        "Shell": { "allow_patterns": ["git *"] }
    }
}
```

## Communication Protocol

### Coroutine Model

Skills are coroutines — they yield control when they need external resources:

```
Runtime                          Skill (binary/wasm/service)
  │                                │
  ├── initialize(context) ──────► │ ← project info, env, config
  │                                │
  ├── execute(params) ───────────► │ ← user's request
  │                                │
  │ ◄── yield: tool_call ─────────┤   "I need code_grep results"
  ├── tool_result ────────────────► │
  │                                │
  │ ◄── yield: ask_user ──────────┤   "Which auth method?"
  ├── user_response ──────────────► │
  │                                │
  │ ◄── yield: spawn_subagent ────┤   "Review this code"
  ├── subagent_result ────────────► │
  │                                │
  │ ◄── yield: llm_call ──────────┤   "Generate commit message"
  ├── llm_response ───────────────► │
  │                                │
  │ ◄── complete(result) ─────────┤   Done
  │                                │
  ├── shutdown() ─────────────────► │
```

### JSON-RPC Messages

**Runtime → Skill:**

```json
{"jsonrpc": "2.0", "method": "initialize", "params": {
    "project": "my-app",
    "cwd": "/path/to/project",
    "env": {"shell": "zsh", "platform": "darwin"},
    "config": {}
}, "id": 1}

{"jsonrpc": "2.0", "method": "execute", "params": {
    "args": "create authentication flow",
    "mode": "interactive"
}, "id": 2}

{"jsonrpc": "2.0", "method": "resume", "params": {
    "yield_id": "y1",
    "result": {"matches": [{"file": "src/auth.ts", "line": 12}]}
}, "id": 3}
```

**Skill → Runtime (yields):**

```json
{"jsonrpc": "2.0", "method": "yield", "params": {
    "yield_id": "y1",
    "type": "tool_call",
    "tool": "code_grep",
    "args": {"pattern": "authenticate", "path": "src/"}
}}

{"jsonrpc": "2.0", "method": "yield", "params": {
    "yield_id": "y2",
    "type": "ask_user",
    "question": "Which authentication method?",
    "options": ["OAuth2 PKCE", "JWT", "Session cookies"]
}}

{"jsonrpc": "2.0", "method": "yield", "params": {
    "yield_id": "y3",
    "type": "spawn_subagent",
    "prompt": "Review this spec for completeness",
    "model": "reasoning",
    "tools": ["FileRead", "code_inspect"]
}}

{"jsonrpc": "2.0", "method": "yield", "params": {
    "yield_id": "y4",
    "type": "llm_call",
    "prompt": "Generate a commit message for this diff: ...",
    "model": "code"
}}

{"jsonrpc": "2.0", "method": "yield", "params": {
    "type": "progress",
    "percent": 45,
    "message": "Phase 2 of 4: implementing auth handler"
}}

{"jsonrpc": "2.0", "method": "yield", "params": {
    "type": "emit_artifact",
    "artifact": {"type": "file", "path": "specs/auth/SPEC.md", "content": "..."}
}}

{"jsonrpc": "2.0", "result": {
    "status": "complete",
    "artifacts": ["specs/auth/SPEC.md"],
    "summary": "Created 4-phase auth spec with OAuth2 PKCE"
}, "id": 2}
```

## Progressive Disclosure

Native skills preserve progressive disclosure at three levels:

### Level 1: Registry Metadata (~20 tokens)

```
ax skills search "commit"
  → commit-go: "Generate conventional commit messages" (binary, 2.1MB)
```

The registry only returns name + description. No code loaded, no context consumed.

### Level 2: Skill Manifest (~50 tokens)

```json
// skill.json — loaded when runtime scans .agents/skills/
{
    "name": "commit",
    "type": "binary",
    "trigger": "/commit",
    "description": "Generate conventional commit messages",
    "capabilities": { "tools_needed": ["Shell"], "subagents": true }
}
```

The runtime knows this skill exists, what triggers it, and what it needs. No binary loaded.
This is what gets injected into the system prompt so the LLM knows `/commit` is available.

### Level 3: Full Execution (0 tokens of LLM context)

```
User: "/commit"
  → Runtime spawns bin/commit-darwin-arm64
  → Skill handles everything internally
  → Yields: tool_call, ask_user, llm_call
  → Returns: commit_sha, message
```

The skill executes WITHOUT consuming LLM context. The LLM doesn't need to read SKILL.md
or follow a protocol — the binary IS the protocol. The only LLM tokens consumed are the
yields that explicitly request `llm_call`.

### Comparison to Markdown Skills

| Disclosure Level | Markdown Skill | Native Skill |
|-----------------|---------------|--------------|
| Registry | Name + description (~20 tokens) | Same |
| Manifest | SKILL.md frontmatter (~50 tokens) | skill.json (~50 tokens) |
| Active | Full SKILL.md injected (~500 tokens) | 0 tokens (binary runs, yields as needed) |
| Resources | Loaded on demand (~2000 tokens each) | N/A (logic is compiled) |
| LLM calls | LLM follows protocol (all reasoning in context) | Explicit yields (only what's needed) |

**Context savings**: A markdown skill like /spec consumes ~3000 tokens of context (SKILL.md + resources). A native skill consumes ~50 tokens (manifest) plus only the specific `llm_call` yields. This is **60x more context-efficient**.

## Relationship to MCP

### What MCP Does

```
MCP Server (external service)
  ├── Exposes tools (stateless request/response)
  ├── Exposes resources (read-only data)
  └── Protocol: JSON-RPC over stdio or SSE
```

MCP connects LLMs to external services: databases, APIs, cloud platforms.
Each MCP tool is a single stateless operation.

### What AHP Skills Do

```
AHP Skill (workflow service)
  ├── Orchestrates multi-step workflows (stateful coroutine)
  ├── Calls tools (including MCP tools)
  ├── Spawns subagents
  ├── Interacts with users
  └── Protocol: JSON-RPC over stdio or HTTP (same transport!)
```

### Do Native Skills Replace MCP?

**No.** They operate at different layers and compose naturally:

```
AHP Skill (/research)
  │
  ├── yield: tool_call("code_grep", ...)        ← AHP tool (local)
  ├── yield: tool_call("UseMcpTool", {          ← MCP tool (external)
  │     server: "github",
  │     tool: "search_repositories",
  │     args: { query: "..." }
  │   })
  ├── yield: tool_call("UseMcpTool", {          ← MCP tool (external)
  │     server: "slack",
  │     tool: "search_messages",
  │     args: { query: "..." }
  │   })
  ├── yield: llm_call("Synthesize findings...")  ← LLM reasoning
  └── complete({ research_hub: "..." })
```

Skills USE MCP tools. Skills don't replace MCP tools.

| Concern | MCP | AHP Skills |
|---------|-----|-----------|
| **What** | Single operations (search, read, write) | Multi-step workflows |
| **State** | Stateless (request/response) | Stateful (coroutine with lifecycle) |
| **Scope** | External services (GitHub, Slack, DB) | Agent workflows (commit, spec, research) |
| **User interaction** | None (tool just returns data) | Yes (ask_user, approval gates) |
| **Subagents** | None | Yes (spawn_subagent with model routing) |
| **LLM calls** | None (tools don't call LLMs) | Yes (yield llm_call for reasoning steps) |
| **Duration** | Milliseconds | Minutes to hours |
| **Protocol** | JSON-RPC over stdio/SSE | JSON-RPC over stdio/HTTP (same transport!) |

### The Convergence Opportunity

MCP and AHP skills share the same transport (JSON-RPC over stdio). A runtime could treat them uniformly:

```
Runtime's tool/skill registry:
  ├── Local tools (code_grep, work_item)     ← in-process
  ├── MCP tools (github, slack, db)          ← stdio/SSE JSON-RPC
  └── AHP skills (/commit, /spec)            ← stdio/HTTP JSON-RPC (same transport!)
```

The difference is the **message vocabulary**, not the transport:
- MCP: `tools/call` → `result` (one round trip)
- AHP: `execute` → `yield*` → `resume*` → `complete` (coroutine)

A future AHP spec could define skills as an **MCP extension** — MCP tools with lifecycle:

```json
// Hypothetical MCP+AHP convergence
{
    "capabilities": {
        "tools": { ... },           // Standard MCP tools
        "skills": {                  // AHP extension
            "lifecycle": true,       // Supports initialize/execute/yield/complete
            "subagents": true,
            "user_interaction": true
        }
    }
}
```

## Purpose-Routed LLM Calls

### Problem

Native skills need LLM reasoning for some steps but not all. Three bad options:

1. Skill embeds its own LLM client → loses multi-model routing, duplicates provider logic
2. All calls go to one cloud model → expensive for classification, slow for extraction
3. Skill hardcodes model names → breaks portability across user configs

### Solution: Purpose Taxonomy

Skills declare WHAT KIND of reasoning they need. The runtime maps purpose to the best available model (local or cloud).

```json
// Skill yields with purpose, not model name:
{
    "type": "llm_call",
    "purpose": "classification",
    "prompt": "Is this a bug fix or feature? Reply with one word.",
    "max_tokens": 10
}
```

### Purpose Tiers

| Purpose | Characteristics | Typical Model | Cost |
|---------|----------------|---------------|------|
| classification | <10 tokens, binary/enum answer | Local 3-4B (Qwen, Phi) | Free |
| extraction | Structured output, JSON/schema | Local 7-14B or Gemini Flash | ~$0.01 |
| analysis | Medium reasoning, summarization | Cloud cheap (GPT-4o-mini, Flash) | ~$0.01-0.05 |
| generation | Quality prose/code, creative | Cloud mid (Sonnet, GPT-4o) | ~$0.05-0.20 |
| reasoning | Complex judgment, multi-step logic | Cloud top (Opus, o3, Gemini Pro) | ~$0.50+ |

### Runtime Model Router

User configures purpose → model mapping:

```json
// .agents/models.json
{
    "routes": {
        "classification": {
            "prefer": "local",
            "local": { "model": "qwen3-4b", "url": "http://localhost:1234/v1" },
            "fallback": "openai:gpt-4o-mini"
        },
        "extraction": {
            "prefer": "local",
            "local": { "model": "qwen3-14b", "url": "http://localhost:1234/v1" },
            "fallback": "google:gemini-2.5-flash"
        },
        "analysis": {
            "prefer": "cloud",
            "model": "openai:gpt-4o-mini"
        },
        "generation": {
            "prefer": "cloud",
            "model": "anthropic:claude-sonnet-4-6"
        },
        "reasoning": {
            "prefer": "cloud",
            "model": "anthropic:claude-opus-4-6"
        }
    },
    "defaults": {
        "prefer": "cloud",
        "model": "anthropic:claude-sonnet-4-6"
    }
}
```

### Local LLM Sources

The runtime manages connections. Skills never call LLMs directly:

```
Runtime Model Router
  ├── Local (free, fast, private)
  │   ├── LM Studio (http://localhost:1234/v1)
  │   ├── Ollama (http://localhost:11434)
  │   └── Docker Model Runner (http://localhost:8080/v1)
  │
  ├── Cloud (configured, paid)
  │   └── 56 providers via Kilo engine
  │
  └── Gateway (optional, enterprise)
      └── Bifrost (load-balanced, cached)
```

### Protocol Extension

```json
// Skill yield with purpose routing:
{
    "jsonrpc": "2.0",
    "method": "yield",
    "params": {
        "yield_id": "y1",
        "type": "llm_call",
        "purpose": "classification",
        "prompt": "Is this a bug fix or feature?",
        "max_tokens": 10,
        "response_format": "text",
        "prefer": "local"
    }
}

// Runtime responds with result + metadata:
{
    "jsonrpc": "2.0",
    "method": "resume",
    "params": {
        "yield_id": "y1",
        "result": "bug fix",
        "metadata": {
            "model": "qwen3-4b",
            "provider": "lm-studio",
            "latency_ms": 45,
            "tokens_in": 23,
            "tokens_out": 3,
            "cost": 0.0
        }
    }
}
```

### Example: /commit with Purpose Routing

```
Step 1: classify diff type
  yield: llm_call(purpose: "classification", prompt: "bug fix or feature?")
  → Local Qwen 3B, 45ms, free

Step 2: analyze changes
  yield: llm_call(purpose: "analysis", prompt: "summarize this diff: ...")
  → GPT-4o-mini, 300ms, $0.01

Step 3: generate commit message
  yield: llm_call(purpose: "generation", prompt: "write commit message for: ...")
  → Claude Sonnet, 1.2s, $0.10

Total: 3 calls, $0.11, 1.5s
vs single-model: 3 calls, $0.30, 3s+
```

### Cost Comparison: /spec Workflow

```
Single model (Claude Sonnet for all 50 calls):
  50 × $0.10 avg = $5.00

Purpose-routed:
  15 classification  × $0.00 (local)  = $0.00
  10 extraction      × $0.01          = $0.10
  15 analysis        × $0.03          = $0.45
  8  generation      × $0.15          = $1.20
  2  reasoning       × $0.50          = $1.00
                                Total = $2.75 (45% savings)
```

### Privacy-Aware Routing

Purpose routing enables privacy controls:

```json
{
    "routes": {
        "classification": { "require_local": true },
        "extraction": { "require_local": true }
    },
    "privacy": {
        "never_send_to_cloud": ["*.env", "*.key", "credentials.*"],
        "redact_patterns": ["API_KEY=\\S+", "password=\\S+"]
    }
}
```

Classification and extraction (which see raw code) stay local. Generation and reasoning
(which see summaries) can use cloud. Source code never leaves the machine for cheap ops.

## Distribution Model

### Three Tiers

| Tier | Format | Install | Security | Use Case |
|------|--------|---------|----------|----------|
| Community | Markdown + scripts | `git clone` into `.agents/skills/` | Trust-based | Personal workflows |
| Official | WASM modules | `ax skills install name` | Sandboxed | Curated, portable |
| Enterprise | Binaries or services | `ax skills install --binary name` | Process-isolated | Commercial |

### Registry

```bash
# Discover
ax skills search "commit"
  commit-go       Official commit workflow (Go binary, 2.1MB)     ★★★★★
  commit-rs       Rust commit generator (WASM, 800KB)             ★★★★
  commit-py       Python commit analyzer (script, requires uv)    ★★★

# Install from registry
ax skills install commit-go

# Install from git
ax skills install github.com/your-org/custom-spec-skill

# Install from local path
ax skills install ./my-skill/

# List installed
ax skills list
  /commit    binary  commit-go v1.0.0    .agents/skills/commit/
  /spec      wasm    spec v2.1.0         .agents/skills/spec/
  /research  service research v1.0.0     http://localhost:9100
  /pragmatic markdown (built-in)         .agents/skills/pragmatic/
```

## Open Questions

- Q1: Should the skill protocol be proposed as an MCP extension or standalone spec?
- Q2: WASM skill sandboxing — what capabilities (fs, network, env) are granted by default?
- Q3: How to handle skill versioning and backward compatibility?
- Q4: Should skills declare their quality level (alpha/beta/stable)?
- Q5: How to handle skill conflicts (two skills claim the same trigger)?
- Q6: Should the registry be centralized (like npm) or federated (like Homebrew taps)?
- Q7: Should skills be able to override purpose routing for specific calls?
- Q8: How to detect local LLM availability at runtime? (probe ports, check processes?)
- Q9: Should the metadata (model, latency, cost) be logged to the traces DB for analytics?
