# Kilocode Contribution Research Hub

**Status**: Active — strategy defined, ready to execute
**Repo**: `Kilo-Org/kilocode` (fork: `peterkc/kilocode`)
**Clone**: `/Volumes/atlas/kilocode` (branch: `main`)
**Sessions**: 1b1f7214 (initial), current (re-audit + strategy)

## Strategy

Three-phase plan to land upstream contributions that independently add value but collectively move kilocode toward AHP architecture (ckd memory, bdx work tracking, native skills).

1. **Credibility** — Bug fixes for high-reaction issues (#3545, #2041, #4262)
2. **Plugins** — Ship AHP concepts as installable plugins (local search, memory, work)
3. **Core proposals** — With credibility + proven plugins, propose storage abstraction and native skills

See `contribution-strategy.md` for full plan with community signal analysis.

## Active Artifacts

| File | Purpose |
|------|---------|
| `contribution-strategy.md` | Three-phase plan, community signals, extension point map |
| `new-repo-analysis.md` | Kilocode monorepo map, tools, agents, storage (re-audited) |
| `decisions.md` | Design decisions D1-D22 |
| `tool-design.md` | AHP tool design: code_grep + code_inspect (Phase 2) |
| `memory-design.md` | AHP memory protocol on ckd/Dolt (Phase 2) |
| `work-protocol-design.md` | AHP work protocol on bdx/Dolt (Phase 2) |
| `native-skills-design.md` | AHP native skill protocol (Phase 3) |
| `opentui-analysis.md` | OpenTUI architecture (reference) |
| `sources.md` | URLs and references |
| `archive/` | Superseded artifacts from initial analysis |

## Key Facts

- **Architecture**: CLI-as-backend (Hono HTTP on port 4096), multi-surface (VSCode, Tauri, web, Zed)
- **Stack**: Bun + SolidJS (app/desktop) + Ink (TUI) + Vercel AI SDK + Drizzle/SQLite
- **Storage**: SQLite via Drizzle ORM — not JSON files. Path: `~/.local/share/kilo/`
- **Plugin system**: 22 hooks, npm/file plugins, no fork needed for tools/auth/prompts
- **Fork of**: opencode, with `kilocode_change` markers for upstream sync
- **Default branch**: `main` (not dev)
- **Contribution bar**: Issue-first policy, conventional commits, precise scope

## Decisions (Active)

| # | Decision | Status |
|---|----------|--------|
| D8 | Bun + OpenTUI recommended | **Validated** — Kilo did exactly this |
| D11 | Separate tools > overloaded search | **Validated** |
| D12 | ckd/Dolt for AHP memory | Opportunity (replaces SQLite) |
| D13 | bdx/Dolt for AHP work tracking | Opportunity (replaces ephemeral todos) |
| D14 | Memory = learned, Work = doing | Opportunity |
| D15 | Native skills (binary/WASM/service) | Opportunity (Phase 3) |
| D16 | Skills compose with MCP | Opportunity |
| D17 | Purpose-routed LLM calls | Opportunity |
| D19 | Kilo already built the rewrite | **Major finding** |
| D20 | CLI-as-backend architecture | Learned |
| D21 | SolidJS over React for new surfaces | Learned |
| D22 | Vercel AI SDK unifies providers | Learned |

See `decisions.md` for full rationale on all 22 decisions.

## Beads

| ID | Title | Status |
|----|-------|--------|
| acf-0u2yl | Epic: Kilo CLI rebuild research | Open |
| acf-uabi2 | code_grep + code_inspect tools | Open |
| acf-qv7wn | AHP memory protocol (ckd/Dolt) | Open |
| acf-zqxv6 | AHP work protocol (bdx/Dolt) | Open |
| acf-ycviq | AHP native skill protocol | Open |
