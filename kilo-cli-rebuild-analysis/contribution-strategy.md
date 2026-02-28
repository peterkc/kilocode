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
**Rubric**: ADR-4001 (score >= 6 to pursue, >= 8 = high priority)

> **2026-02-25 audit**: 5 of 7 original candidates were resolved/irrelevant for the new CLI.
> The ground-up CLI rebuild (Bun + Vercel AI SDK + models.dev) resolved many old extension bugs.
> See kc-9uu, kc-qcq, kc-njd, kc-83y close reasons for details.

**Tier 1 — First PR target:**

| Issue | Title | Score | Beads | Status |
|-------|-------|-------|-------|--------|
| #6018 | Gemini thought_signature | 9 (demand:2 scope:2 avail:2 align:2 signal:1) | kc-nm7 | **ACTIVE** |

3-file fix across provider/session layers. Demonstrates system-level thinking through
message lifecycle, providerMetadata preservation, and SDK contract understanding.
Touches provider abstraction layer where Phase 2/3 influence matters.

**Tier 2 — Follow-up PRs:**

| Issue | Title | Score | Beads | Status |
|-------|-------|-------|-------|--------|
| #6046 | Snapshot gc (68GB legacy dir) | 6 (demand:0 scope:2 avail:2 align:1 signal:1) | kc-6ov | Open |
| #6026 | Show x-request-id in errors | 6 (demand:0 scope:2 avail:2 align:1 signal:1) | kc-4tr | Open |
| #6310 | Mouse scroll cycles history | 5 (demand:0 scope:1 avail:2 align:1 signal:1) | kc-e2d | Open |

**Closed (resolved in new CLI architecture):**

| Issue | Title | Reason | Beads |
|-------|-------|--------|-------|
| #3545 | Anthropic custom model names | Dynamic models.dev registry | kc-9uu (closed) |
| #4331 | Ollama Cloud regression | VSCode-only, no Ollama in CLI | kc-qcq (closed) |
| #3608 | Bedrock/Vertex native tools | Native AI SDK providers | kc-njd (closed) |
| #6051 | Broken link Speech Rec | Two PRs already submitted | kc-83y (closed) |

**Lesson**: Always verify issue roster against CURRENT codebase before speccing.

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

## Team Intelligence (verified 2026-02-27)

### Actual Team (COLLABORATOR status via GraphQL)

| Login | Focus | Reviews externals? |
|-------|-------|-------------------|
| marius-kilocode | Agent Manager, VSCode extension | No — self-merges features |
| kevinvandijk | CLI lead, releases, providers, upstream sync | **Yes — primary external reviewer** |
| chrarnoldus | Backend — gateway, models, provider config | Yes — bot PRs, backend |
| iscekic | VSCode — sessions, URI handler | Occasionally |

### Trusted External Contributors (CONTRIBUTOR, self-merge rights)

| Login | Focus | Note |
|-------|-------|------|
| markijbema | CLI features, CI, dev tooling | 8 PRs in last 80 merged |
| catrielmuller | Build/CI, binary, infra | 7 PRs, self-merges |
| lambertjosh | Docs, design, product | 5 PRs, self-merges |
| olearycrew | DevRel, docs, community | 2 PRs |

### Trust Ladder

NONE → CONTRIBUTOR → trusted CONTRIBUTOR (self-merge) → COLLABORATOR

Olusammytee (18 issue-closing PRs) and Githubguy132010 (10) are on the path up.
Our PR #6368 establishes us as CONTRIBUTOR.

### Merge Patterns

- **Volume**: ~20 PRs/day, accelerating (4/day late Jan → 30/day late Feb)
- **Speed**: Same-day turnaround typical. If not picked up in a week, likely won't be
- **Schedule**: Mon-Sat active, Sun near-zero. Peak: 10-16 UTC
- **Team builds features; community fixes bugs** — clear division of labor
- **Self-merge is the reward** for consistent quality contributions

### What Gets Merged from Externals

- **High merge probability**: Provider/config bugs (model IDs, field stripping, limits), docs fixes, CI/tooling
- **Medium**: CLI UX bugs with clear repro, MCP config issues
- **Low**: Deep architecture changes (team owns those), large features, vague reports
- Issue-first policy: all PRs must reference existing issue
- Conventional commit format expected

### What Predicts Review Attention

| Factor | Weight |
|--------|--------|
| kevinvandijk sees it | Critical — merges 60%+ of external PRs |
| Issue has `kilo-triaged` label | High — team acknowledged it |
| Small, mechanical fix (1-3 files) | High |
| Bug, not feature | High |
| `blocking` label | Medium-High |
| `good first issue` / `contributor` label | Medium |
| Clean conventional commit | Expected |

### Community Signal Summary

#### Highest-Demand Issues (by reactions)

| Reactions | Issue | Theme | Status |
|-----------|-------|-------|--------|
| 19 | #3545 Anthropic-compatible API | Provider flexibility | Resolved in new CLI |
| 17 | #4331 Ollama Cloud broken | Local LLM regression | Resolved in new CLI |
| 16 | #5460 Gemini CLI provider removed | Provider removal | Team decision, contested |
| 15 | #3063 Import settings from VSCode | Onboarding | Large feature, Phase 2 |
| 12 | #3679 Shift+Enter newline | UX regression | — |
| 10 | #1678 Codebase indexing stuck at 0% | Core feature broken | — |

#### Team Direction (from recent team-filed issues)

- Provider routing in CLI (#6312, #6315)
- MemoryBank migration (#6091)
- Agent-scoped MCP filtering (#6060)
- Agent Manager features (diff viewer, image paste, session import)

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

## Phase 1 Execution Status (2026-02-27)

### Approach: Triage-First

Investigate all candidates thoroughly before submitting PRs. Quality triage comments
build credibility and demonstrate codebase understanding. Systematic PR creation follows.

### Active PR
- **#6018** (PR #6368) — Gemini thoughtSignature test coverage. Bot recommends merge.

### PR Candidate
- **#6277** — Sidebar context % uses `limit.context` instead of `limit.input`. 3-5 line fix.

### Confirmed Already Fixed (triage value: comments demonstrate expertise)
- **#6443** — temperature:0 default. Fixed in 0c7f0cfa2e (v1.0.13).
- **#6248** — read_file OOB. Resolved by v7.x architecture migration. Cross-issue cluster posted.

### Pending Investigation (8 issues, dedicated sessions each)
See kc-934 epic notes for batch plan and investigation goals.

### Superseded
- ~~#3545~~ — Resolved in new CLI (dynamic models.dev registry).
