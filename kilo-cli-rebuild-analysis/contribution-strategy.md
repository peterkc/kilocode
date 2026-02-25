# Kilocode Contribution Strategy

**Date**: 2026-02-25
**Repo**: Kilo-Org/kilocode (fork: peterkc/kilocode)
**Goal**: Land PRs that independently add value but collectively move toward AHP architecture

## Architecture We Want

```
Current:  SQLite (single-node) + JSON skills + Exa-only search
Target:   Dolt (versioned, multi-project, team-shared) + native skills + local+cloud search
```

## Extension Points (No Fork Required)

| Hook | What We Can Do |
|------|---------------|
| `tool` (plugin) | Register custom tools (e.g., local search, memory query) |
| `event` (plugin) | Observe all bus events (session, message, tool, compaction) |
| `experimental.chat.system.transform` | Inject memory/context into system prompt |
| `experimental.session.compacting` | Custom compaction with memory-aware summarization |
| `tool.execute.after` | Post-process tool results (e.g., enrich with memory) |
| `shell.env` | Inject env vars for ckd/bdx integration |
| `auth` (plugin) | Register custom auth providers |
| `.opencode/tool/*.ts` | File-based custom tools (no plugin wrapper needed) |
| `.opencode/agents/*.md` | Custom agent definitions |
| `.opencode/command/*.md` | Custom slash commands |

## What Requires Core Fork

| Change | Why |
|--------|-----|
| SQLite -> Dolt backend | Hardcoded bun:sqlite in db.ts, Drizzle sqliteTable schema |
| New bus event types | BusEvent.define() only callable from core |
| New experimental config flags | Zod schema in config.ts |
| New bundled provider loaders | BUNDLED_PROVIDERS / CUSTOM_LOADERS hardcoded |
| Plugins publishing bus events | PluginInput has no Bus reference |
| Re-register multiedit/ls tools | Registry imports are in core |

## Three-Phase Contribution Plan

### Phase 1: Credibility (Weeks 1-3)

**Goal**: Get 2-3 PRs merged to establish contributor reputation.

| PR | Issue | Effort | Impact |
|----|-------|--------|--------|
| Fix Anthropic-compatible custom model names | #3545 (19 rxn) | Low — model name handling in types/providers | Highest community demand |
| Fix MCP "Always allow" persistence | #2041 | Low — config write path | Frequent user complaint |
| Error surface for API failures | #4262 (8 rxn) | Medium — provider error handling | High frustration |

**Pattern**: Precise bug fixes with clear scope. Match what gets merged from externals.

### Phase 2: Plugin Ecosystem (Weeks 4-8)

**Goal**: Demonstrate AHP concepts as kilocode plugins, building community demand.

| Plugin | What It Does | AHP Concept |
|--------|-------------|-------------|
| `kilo-local-search` | Local ripgrep + tree-sitter search tool (no Exa needed) | code_grep + code_inspect (D11) |
| `kilo-memory` | Cross-session memory via ckd/Dolt, injected via system.transform | Memory protocol (D12) |
| `kilo-work` | Persistent work items via bdx/Dolt, replacing ephemeral todos | Work protocol (D13) |

These ship as npm packages (`@peterkc/kilo-local-search`, etc.) installable via `plugin: ["@peterkc/kilo-local-search"]` config. Users can try them without any core changes.

**Key**: Plugin tools access the REST API via `PluginInput.client`, not the DB directly. This means the memory/work plugins communicate through HTTP, which is slower but doesn't require forking.

### Phase 3: Core Proposals (Weeks 8+)

**Goal**: With credibility + proven plugins, propose core changes via RFCs/issues.

| Proposal | Evidence | Core Change |
|----------|----------|-------------|
| Storage backend abstraction | Plugin memory/work tools prove demand | Abstract db.ts behind interface, add Dolt adapter |
| Local search as built-in tool | Plugin adoption metrics | Register as built-in alongside codesearch |
| Plugin bus publish capability | Event hook usage patterns | Add Bus reference to PluginInput |
| Native skill protocol | Skill tool usage + SKILL.md limitations | Binary/WASM skill loading (D15) |

## Community Signal Summary

### Highest-Demand Issues (by reactions)

| Reactions | Issue | Theme |
|-----------|-------|-------|
| 19 | #3545 Anthropic-compatible API | Provider flexibility |
| 17 | #4331 Ollama Cloud broken | Local LLM regression |
| 16 | #5460 Gemini CLI provider removed | Provider removal |
| 15 | #3063 Import settings from VSCode | Onboarding |
| 12 | #3679 Shift+Enter newline | UX regression |
| 10 | #1678 Codebase indexing stuck at 0% | Core feature broken |

### Team Direction (from recent team-filed issues)

- Provider routing in CLI (#6312, #6315)
- MemoryBank migration (#6091)
- Agent-scoped MCP filtering (#6060)
- Agent Manager features (diff viewer, image paste, session import)

### What Gets Merged from Externals

Precise bug fixes, docs, CI/tooling. No large feature PRs from externals in recent history.
Issue-first policy: all PRs must reference existing issue.

## Contribution Workflow

```bash
# 1. Branch from upstream
git fetch upstream && git checkout -b fix/description upstream/main

# 2. Keep diffs minimal
# Use kilocode_change markers for shared files
# Kilo-specific code -> packages/opencode/src/kilocode/

# 3. Reference our research
# Link to peterkc/kilocode orphan branches in PR description

# 4. PR to upstream
git push origin fix/description
gh pr create --repo Kilo-Org/kilocode --base main
```

## Decision: First PR Target

**#3545 Anthropic-compatible custom model names** — 19 reactions, well-scoped to model name handling,
clear user demand, matches our provider flexibility values. This establishes us as a contributor
who fixes real user pain, not a drive-by feature requester.
