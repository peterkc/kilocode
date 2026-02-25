# Kilocode Repo Analysis (Kilo-Org/kilocode)

**Date**: 2026-02-25 (re-audited after repo correction)
**Source**: `Kilo-Org/kilocode` main branch, 280K LoC
**Note**: Initial analysis was against archived `Kilo-Org/kilo`. Re-audited against active `Kilo-Org/kilocode`.

## Architecture Overview

CLI-as-backend: the opencode CLI (`packages/opencode/`) runs a Hono HTTP server on port 4096. All frontends (VSCode, desktop, web, Zed) are thin clients that talk HTTP/SSE.

```
packages/
  opencode/      @kilocode/cli          Core CLI + HTTP server + all tools
  sdk/js/        @kilocode/sdk          Auto-generated TypeScript SDK
  app/           @opencode-ai/app       SolidJS web/desktop frontend (reference UI)
  desktop/       @opencode-ai/desktop   Tauri v2 (Rust) desktop wrapper
  kilo-vscode/   @kilocode/kilo-vscode  VSCode extension (SolidJS webview -> CLI backend)
  kilo-gateway/  @kilocode/kilo-gateway Auth + provider routing (OpenRouter-based)
  kilo-telemetry/@kilocode/kilo-telemetry PostHog + OpenTelemetry
  kilo-i18n/     @kilocode/kilo-i18n    Internationalization
  kilo-ui/       @kilocode/kilo-ui      Kobalte-based SolidJS component library
  ui/            @opencode-ai/ui        Upstream UI components
  util/          @opencode-ai/util      Shared utilities
  plugin/        @kilocode/plugin       Plugin/tool interface definitions
  extensions/zed/                        Zed editor extension (ACP protocol)
  containers/                            CI Docker images
  kilo-docs/                             Documentation site
```

## Module Map (packages/opencode/src/)

| Module | Purpose |
|--------|---------|
| agent/ | Agent registry + built-in agents (code, plan, debug, orchestrator, ask, explore) |
| tool/ | 21 built-in tools (bash, read, write, edit, multiedit, apply_patch, glob, grep, ls, task, webfetch, websearch, codesearch, todowrite, skill, question, lsp, batch, plan_enter/exit, invalid) |
| skill/ | Multi-path skill discovery (.claude/skills/, .agents/skills/, .kilocode/, .opencode/, config paths, URL packs) |
| mcp/ | MCP client (stdio + SSE + StreamableHTTP + OAuth PKCE) |
| plugin/ | Plugin system with 22 hook points |
| provider/ | 22+ AI provider SDKs via Vercel AI SDK |
| session/ | Session lifecycle, streaming, compaction, revert/snapshot, forking, sharing |
| server/ | Hono HTTP server, SSE, OpenAPI spec, mDNS |
| acp/ | Agent Client Protocol (JSON-RPC stdio for Zed) |
| lsp/ | 20 bundled language servers, LSP tool |
| permission/ | Two-tier: legacy (ask/always/reject) + PermissionNext (rule-based allow/deny/ask) |
| config/ | JSONC config, migration hooks from legacy Roo-Code/Cline |
| worktree/ | Git worktree full lifecycle |
| snapshot/ | Shadow git repo for per-session file tracking |
| storage/ | JSON file store with locks |
| cli/ | Commands, TUI (Ink), themes |
| bus/ | Typed pub/sub event bus |
| pty/ | bun-pty pseudo-terminal with WebSocket |

## Tool Comparison (Old vs New)

### Removed from old

| Tool | Old | New Status |
|------|-----|------------|
| attempt_completion | Explicit task completion signal | Gone — conversational end |
| browser_action | Puppeteer browser control | Gone entirely |
| generate_image | AI image generation | Gone |
| codebase_search | Local embedding vector search (LanceDB) | Replaced by Exa external API (codesearch) |
| use_mcp_tool | Meta-tool to invoke MCP tools | Gone — MCP tools are first-class via plugin |
| access_mcp_resource | Read MCP resource | Gone — absorbed into plugin system |
| switch_mode | Switch agent modes | Replaced by plan_enter/exit (limited, experimental) |
| delete_file | Delete file/directory | Gone — use bash |
| condense | Trigger conversation compaction | Gone — automatic |
| new_rule | Create rule file | Gone |

### Added in new

| Tool | Description |
|------|-------------|
| skill | Load SKILL.md into context (compatible with Claude Code) |
| lsp | Go-to-definition, find-references, hover, call hierarchy, workspace symbols (experimental) |
| batch | Execute up to 25 tool calls in parallel (experimental) |
| multiedit | Multiple sequential edits to one file |
| websearch | Exa web search |
| codesearch | Exa code/library doc search |
| plan_enter/exit | Mode transition (experimental, CLI-only) |
| question | Structured user questions with options |

### Improved

| Tool | Change |
|------|--------|
| edit | 9 fuzzy-matching strategies (Levenshtein, block-anchor, whitespace normalization, etc.) vs exact-match |
| apply_patch | Multi-file hunks, add/update/delete/move, LSP diagnostics post-apply |
| task | Resumable subagent sessions (vs one-shot mode-based subtasks) |

## Agent System

| Agent | Type | Description |
|-------|------|-------------|
| code | primary | Default. Full tool access |
| plan | primary | Read-only, edits only .opencode/plans/ |
| debug | primary (Kilo) | Systematic: reflects on 5-7 root causes before fixing |
| orchestrator | primary (Kilo) | Coordinates parallel subagent waves |
| ask | primary (Kilo) | Read-only Q&A, no edits |
| general | subagent | Multi-step implementation |
| explore | subagent | Fast codebase exploration (quick/medium/very thorough) |

Per-agent permission rulesets (PermissionNext): ordered rules evaluated first-match.

## Plugin System (22 hooks)

Pre-LLM: config, chat.message, chat.params, chat.headers, experimental.chat.messages.transform, experimental.chat.system.transform
Tool lifecycle: tool.execute.before, tool.execute.after, tool.definition
Permission: permission.ask
Session: experimental.session.compacting, experimental.text.complete
System: event, tool (register tools), auth, command.execute.before, shell.env

Internal plugins: KiloAuth, CodexAuth, CopilotAuth, GitlabAuth
External: npm packages or file:// paths, installed via Bun at runtime

## Skill Compatibility

Skills from Claude Code (`.claude/skills/`) are automatically discovered. The skill tool loads `SKILL.md` files with YAML frontmatter into the system prompt.

Discovery order (later wins):
1. `~/.claude/skills/`, `~/.agents/skills/` (global)
2. `.claude/skills/`, `.agents/skills/` (project, walking up)
3. `.kilocode/skills/`, `.opencode/skills/` (native)
4. config.skills.paths[], config.skills.urls[]

## Provider Count

22+ providers via Vercel AI SDK. Dynamic provider loading via Bun (npm install at runtime).

## Storage (CORRECTED — not JSON files)

**Re-audit finding**: Active kilocode uses **SQLite via Drizzle ORM** (1.0.0-beta.12), NOT plain JSON files.

Tables:
- `session` — session lifecycle, revert state, permission rulesets
- `message` — role + data (JSON)
- `part` — text, reasoning, tool, patch, compaction (JSON data column)
- `todo` — session-scoped task list with priority + position
- `permission` — per-project PermissionNext rulesets
- `project` — project registry
- `share` — session sharing state
- `control` — control plane state

Storage path: `~/.local/share/kilo/storage/` (kilocode-branded, not opencode)

This significantly changes our contribution surface — adding a Dolt backend would be replacing SQLite, not JSON files.

## Tool Registry Corrections (Re-audit)

Tools that exist on disk but are **NOT registered** in the active repo:
- `multiedit` — file exists, NOT in registry (dropped since archived repo)
- `ls` (ListTool) — file exists, NOT in registry (dropped)
- `todoread` — file exists, COMMENTED OUT in registry

## Config Corrections (Re-audit)

Config file search order: `kilo.jsonc` > `kilo.json` > `opencode.jsonc` > `opencode.json`
Config directories: `.kilo/` and `.opencode/` (both scanned)
Legacy migrators: ModesMigrator, WorkflowsMigrator, RulesMigrator, McpMigrator, IgnoreMigrator

## Key Gaps (vs old + vs ideal)

1. **No local semantic search** — only Exa external API. Offline/private codebases lose search capability
2. **No browser automation** — removed entirely
3. **Storage is SQLite** — queryable but single-node, no versioning, no cross-project queries
4. **Skills are text injection** — no binary/WASM/service skills
5. **No purpose-routed LLM** — model-conditional tool routing exists (apply_patch vs edit) but not skill-level
6. **TUI still Ink** — OpenTUI is a dependency but not wired into the terminal TUI yet
7. **multiedit and ls tools dropped** — existed in archived repo, not registered in active
