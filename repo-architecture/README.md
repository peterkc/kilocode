# Kilocode Repository Architecture

Research into Kilocode's repo structure, release series, and architecture evolution.

## Key Findings

### Three Release Series (Same Repo)

The `Kilo-Org/kilocode` repo has produced three distinct release streams.
They were NOT concurrent — the v5.x series ended when v7.x began.

| Series | Product | Dates | Architecture | Assets |
|--------|---------|-------|--------------|--------|
| v4.x → v5.9.0 | VSCode Extension | → Feb 22, 2026 | Old monorepo (`src/core/`) | `.vsix` only |
| v1.0.x | Desktop + CLI (early) | Feb 23, 2026 | New opencode-based | `.zip` + `.vsix` |
| v7.0.x | Unified (CLI + VSCode + Desktop) | Feb 23, 2026 → | New opencode-based | All platforms |

### The v5.x → v7.x Transition

- **v5.9.0** (Feb 22): Last release on old architecture. Commit `68250007c0`.
- **v7.0.26** (Feb 23): First unified release on opencode architecture. Ships from `main`.
- **v1.0.25** (Feb 23): Desktop-only release, also opencode-based.
- These are **not ancestor-descendant** — v5.9.0's commit is not an ancestor of v7.0.26.

The old code (`src/`) was replaced entirely by `packages/opencode/` + `packages/kilo-vscode/`.

### Legacy Repo

`Kilo-Org/kilocode-legacy` holds the old VSCode extension source:
- README: "This repository is no longer actively maintained"
- Only release: v5.9.0 (re-published Feb 26)
- Still receiving minor commits (renames, rebranding) but no feature work
- **Not archived** yet, but functionally EOL

### VS Code Marketplace

The marketplace extension (`kilocode.Kilo-Code`) now publishes v7.x (7.0.33 as of Feb 27).
Users on v5.9.0 will get auto-updated to v7.x.

## Package Structure Evolution

### v5.9.0 (Old Architecture)

```
src/
  core/
    tools/ReadFileTool.ts       # read_file tool (class-based)
    prompts/tools/              # Tool descriptions
  integrations/
    misc/read-lines.ts          # Line reading utility (zero-based)
packages/
  agent-runtime/                # Separate agent runtime
  core/                         # Core schemas
  types/                        # Shared types
```

### v7.x (Current Architecture)

```
packages/
  opencode/                     # Core CLI + tool implementations
    src/tool/read.ts            # read tool (functional, 1-based)
  kilo-vscode/                  # VSCode extension wrapper
  desktop/                      # Desktop app (Tauri)
  app/                          # Shared app layer
  plugin/                       # JetBrains plugin
  kilo-docs/                    # Documentation site
```

## Version Detection

```bash
# Check which architecture a version uses
gh release view <tag> --repo Kilo-Org/kilocode --json tagName,targetCommitish
git show <commit>:packages/opencode/src/tool/read.ts  # exists = new arch
git show <commit>:src/core/tools/ReadFileTool.ts       # exists = old arch
```

## Implications for Issue Triage

1. Bugs filed against v5.x may already be fixed in v7.x (different codebase)
2. v5.x is EOL — no patches forthcoming
3. The `read_file` tool was completely rewritten during the migration
4. Error messages, parameter names, and indexing conventions all changed

## Sources

- `gh release list --repo Kilo-Org/kilocode`
- `gh repo view Kilo-Org/kilocode-legacy`
- VS Code Marketplace: kilocode.Kilo-Code
- Git history: `git show 68250007c0:src/integrations/misc/read-lines.ts`
- Commit `006d673ed`: "make read tool offset 1 indexed instead of 0"
