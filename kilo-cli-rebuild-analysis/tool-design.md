# Tool Design: code_grep + code_inspect

**Beads**: acf-uabi2
**Depends on**: Phase 3 (membrane interface) of migration plan

## Problem

Kilo's `codebase_search` tool is embedding-only: chunk codebase, embed with LLM API, vector search.
This requires an OpenAI API key + Qdrant/LanceDB for basic code search. It cannot do structural
queries (callers, references) or literal text search (regex, exact strings).

## Proposed: Three-Tool Search Architecture

```
┌───────────────────────────────────┐
│ codebase_search (existing)        │
│ Semantic / conceptual search      │
│ Backend: LanceDB / Qdrant         │
│ "find code related to auth flow"  │
│ Status: optional (needs API key)  │
└───────────────────────────────────┘

┌───────────────────────────────────┐
│ code_grep (NEW)                   │
│ Exact text / regex search         │
│ Backend: ripgrep (bundled)        │
│ "TODO:", "processToken(", "*.ts"  │
│ Status: always available          │
└───────────────────────────────────┘

┌───────────────────────────────────┐
│ code_inspect (NEW)                │
│ Structural + temporal queries     │
│ Backend: ckd (Dolt-backed AST)    │
│ "callers of X", "history of Y"   │
│ Status: available when ckd is     │
└───────────────────────────────────┘
```

## Why Separate Tools

LLMs pick tools based on their description. A single overloaded tool forces the LLM to guess
which search strategy applies. Separate tools let the LLM reason:

- Know the exact string? → `code_grep`
- Know the symbol name, need structure? → `code_inspect`
- Fuzzy conceptual query? → `codebase_search`

Precedent: Claude Code uses Grep (literal), Glob (patterns), and Task(Explore) (semantic)
as separate tools. The LLM learns when to use each.

## Tool Specifications

### code_grep

```typescript
interface CodeGrepParams {
    pattern: string        // Text or regex to search for
    path?: string          // Directory to scope search
    include?: string       // File glob filter (e.g. "*.ts", "*.py")
    context_lines?: number // Lines of context around matches (default: 2)
}

interface CodeGrepResult {
    filePath: string
    lineNumber: number
    lineContent: string
    contextBefore: string[]
    contextAfter: string[]
}
```

**Backend**: `@vscode/ripgrep` (already bundled in Kilo) or system `rg`.

**System prompt description**:
```
Search for exact text or regex patterns in files. Use this when you know
what string or pattern to look for. Returns matching lines with file
paths and line numbers. Fast and always available.
```

**Implementation**: Thin wrapper around ripgrep JSON output. ~50 lines.

### code_inspect

```typescript
interface CodeInspectParams {
    symbol: string         // Function, class, or variable name
    action:                // What to inspect
        | "definition"     // Where is this defined?
        | "references"     // Where is this used?
        | "callers"        // Who calls this function?
        | "history"        // Git change history for this symbol
        | "changes_since"  // What changed since a date/commit?
    path?: string          // Scope to a directory
    since?: string         // For history/changes_since — date or commit hash
}

interface CodeInspectResult {
    // For definition:
    definition?: {
        filePath: string
        lineNumber: number
        signature: string
        docstring?: string
    }

    // For references/callers:
    references?: Array<{
        filePath: string
        lineNumber: number
        context: string
        callerFunction?: string  // For "callers" action
    }>

    // For history/changes_since:
    history?: Array<{
        commit: string
        author: string
        date: string
        summary: string
        diffStats?: string
    }>
}
```

**Backend**: ckd CLI or ckd Dolt queries.

**System prompt description**:
```
Inspect code structure: find where symbols are defined, who calls them,
all references, and their git change history. Use this when you need to
understand how code connects or when it last changed. Powered by AST
analysis and git history.
```

**Implementation**: Calls ckd CLI with structured output, parses JSON. ~100 lines.
Falls back gracefully if ckd is not installed (returns error message suggesting code_grep).

### codebase_search (existing, unchanged)

Keep as-is. Optional semantic search for natural-language conceptual queries.
With the membrane, the backend becomes pluggable (Qdrant, LanceDB, or future ckd embeddings).

## Agent Behavior Examples

### Bug fix workflow

```
User: "Fix the bug in processToken"

Agent:
  1. code_grep("processToken")
     → finds 12 occurrences across 4 files
  2. code_inspect("processToken", "definition")
     → src/core/tokenizer.ts:45, signature, docstring
  3. code_inspect("processToken", "callers")
     → called by parseStream(), handleChunk(), batchProcess()
  4. code_inspect("processToken", "history")
     → last changed 3 days ago by @alice: "refactor token validation"
  5. [reads the function, identifies the bug, fixes it]
```

### Feature addition workflow

```
User: "Add rate limiting to the API"

Agent:
  1. codebase_search("rate limiting")
     → finds existing RateLimiter class (score 0.89)
  2. code_grep("rateLimit")
     → finds config constants in settings.ts
  3. code_inspect("apiHandler", "references")
     → finds all API entry points that need rate limiting
  4. [implements rate limiting at each entry point]
```

### Refactoring workflow

```
User: "Rename AuthService to AuthenticationService"

Agent:
  1. code_inspect("AuthService", "definition")
     → src/services/auth.ts:12
  2. code_inspect("AuthService", "references")
     → 34 references across 15 files
  3. code_grep("AuthService")
     → catches string literals, comments, config keys (47 total)
  4. [renames all occurrences safely]
```

## Provider Interface (Membrane Integration)

```typescript
// In the membrane, tools import provider interfaces:

interface GrepProvider {
    search(pattern: string, options?: GrepOptions): Promise<GrepResult[]>
    isAvailable(): boolean
}

interface InspectProvider {
    definition(symbol: string, path?: string): Promise<DefinitionResult | null>
    references(symbol: string, path?: string): Promise<ReferenceResult[]>
    callers(symbol: string, path?: string): Promise<CallerResult[]>
    history(symbol: string, since?: string): Promise<HistoryEntry[]>
    isAvailable(): boolean
}

interface SemanticSearchProvider {
    search(query: string, path?: string): Promise<SearchResult[]>
    isAvailable(): boolean
    isConfigured(): boolean
}

// CLI wires in:
//   GrepProvider       → RipgrepProvider (always available)
//   InspectProvider    → CkdInspectProvider (available when ckd installed)
//   SemanticProvider   → LanceDBProvider (optional, local embeddings)

// VSCode wires in:
//   GrepProvider       → RipgrepProvider (same)
//   InspectProvider    → VSCodeLanguageServerProvider (LSP-based)
//   SemanticProvider   → QdrantProvider (existing CodeIndexManager)
```

## Dependency Requirements

| Tool | Binary | Install | Fallback |
|------|--------|---------|----------|
| code_grep | ripgrep | Already bundled (`@vscode/ripgrep`) | None needed |
| code_inspect | ckd | `brew install ckd` or from releases | Error: "ckd not found, use code_grep" |
| codebase_search | None (API calls) | API key configuration | Error: "indexing not configured" |

Zero external API keys required for the default path (grep + inspect).

## Migration Sequence

```
Phase 3:   Membrane interface (tools become pluggable)
Phase 3a:  Add code_grep tool (trivial — ripgrep wrapper)
Phase 3b:  Add code_inspect tool (ckd integration)
Phase 3c:  Make codebase_search use membrane provider
Phase 4:   Distribution (bundle ckd with compiled binary?)
```

## Open Questions

- Q1: Should ckd be bundled in the Kilo binary, or required as a separate install?
- Q2: Can ckd index incrementally on file save (watch mode), or only on git events?
- Q3: Should code_inspect fall back to tree-sitter for basic definition/reference
  lookup when ckd is not available? (OpenTUI already bundles tree-sitter WASM)
- Q4: Should code_grep support colgrep-style semantic search as a hybrid mode?
