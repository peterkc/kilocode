# Migration Plan: Bun + OpenTUI

Four-phase plan for migrating Kilo CLI from Node.js + Ink + VSCode shim to Bun + OpenTUI + membrane interface.

**Total timeline**: ~4 months, each phase independently shippable.

## Phase 1: Bun Runtime (Weeks 1-3)

**Goal**: Ship the existing CLI on Bun instead of Node.js. No architectural changes.

```bash
# Today
node dist/index.js

# After Phase 1
bun dist/index.js
```

### Steps

1. **Dependency audit** — Run full test suite under Bun. Flag packages using Node.js-specific APIs not in Bun
2. **Native addon verification** — `@vscode/ripgrep` (binary), `tiktoken` (WASM), `node-pty` (N-API)
3. **Build migration** — Replace esbuild config with `bun build`. Drop Turbo for CLI package
4. **Verify** — All 297 test files pass under Bun. CI runs on Bun

### Risks

- `node-pty` uses N-API — Bun supports N-API but edge cases exist
- `puppeteer-core` should work (Bun is Chromium-compatible)
- `node-ipc` (Unix domain sockets) — needs verification

### Payoff

- ~3-4x faster cold start
- Faster `bun install` for users
- Foundation for Phase 2 (bun:ffi enables OpenTUI)

## Phase 2: OpenTUI Rendering (Weeks 4-7)

**Goal**: Replace Ink with OpenTUI's React reconciler. Same JSX, dramatically better streaming.

### Entry Point Change

```typescript
// BEFORE (Ink)
import { render } from "ink"
render(React.createElement(App, props))

// AFTER (OpenTUI)
import { createRoot } from "@opentui/react"
import { createRenderer } from "@opentui/core"

const renderer = createRenderer()
const root = createRoot(renderer)
root.render(React.createElement(App, props))
renderer.start()
```

### Component Mapping

| Ink Component | OpenTUI Equivalent |
|--------------|-------------------|
| `<Box>` | `<box>` |
| `<Text>` | `<text>` |
| `<Static>` | `<box>` with manual key management |
| `useInput()` | OpenTUI keyboard event system |
| `useStdin()` | OpenTUI input handling |
| `<Newline>` | `<br>` |
| Custom `<MarkdownText>` | `<markdown>` (built-in) |
| Custom diff rendering | `<diff>` (built-in) |
| `<MultilineTextInput>` | `<textarea>` (built-in) |

### LLM Streaming Integration (Highest Impact)

```typescript
// BEFORE: Token -> JS string -> React setState -> full re-render
onToken(token) {
    setOutput(prev => prev + token)  // triggers full React reconciliation
}

// AFTER: Token -> zero-copy write to Zig ring buffer
const feed = createNativeSpanFeed(renderer)
onToken(token) {
    feed.write(token)  // bypasses React entirely for streaming text
}
```

### Steps

1. `bun add @opentui/core @opentui/react`
2. Migrate leaf components (StatusBar, ThinkingAnimation, HotkeyBadge)
3. Migrate containers (CommandInput, ApprovalMenu, AutocompleteMenu)
4. Wire NativeSpanFeed for LLM streaming output
5. Migrate root (App.tsx, UI.tsx)
6. `bun remove ink ink-link ink-testing-library`

### Risks

- Component API differences (`<Static>` scrollback, `measureElement`)
- OpenTUI requires Zig installed for development builds (prebuilts for CI/users)
- Jotai integration should work unchanged (triggers React re-renders)

### Payoff

- LLM streaming: ~450ms -> ~6ms (75x improvement)
- Frame rendering: JS string concat -> Zig cell diff (order of magnitude)
- Terminal capabilities: Kitty keyboard, Sixel graphics, Unicode mode 2026
- Built-in rich components: `<markdown>`, `<code>`, `<diff>`, `<input>`, `<select>`

## Phase 3: Membrane Interface (Weeks 8-13)

**Goal**: Replace the 1,500-line VSCode shim with a ~200-line KiloRuntime membrane.

### Interface Definition

```typescript
interface KiloRuntime {
    fs: {
        read(path: string): Promise<string>
        write(path: string, content: string): Promise<void>
        stat(path: string): Promise<FileStat>
        watch(glob: string, cb: (event: FileEvent) => void): Disposable
    }
    config: {
        get<T>(key: string): T
        set(key: string, value: unknown): Promise<void>
        onDidChange: Event<string>
    }
    messages: {
        send(type: string, payload: unknown): void
        on(type: string, handler: (payload: unknown) => void): Disposable
    }
    env: {
        machineId: string
        shell: string
        language: string
        cwd: string
    }
    context: {
        globalState: Memento
        secrets: SecretStorage
    }
}
```

### Two Implementations

```typescript
// CLI implementation — direct Bun operations
class CLIRuntime implements KiloRuntime {
    fs = new BunFileSystem(this.cwd)
    config = new FileBackedConfig(configPath)
    messages = new DirectMessageBus()       // in-process function calls
    env = { machineId, shell, language, cwd }
    context = new FileBackedState(statePath)
}

// VSCode implementation — wraps real APIs
class VSCodeRuntime implements KiloRuntime {
    fs = new VSCodeFileSystem(vscode.workspace)
    config = new VSCodeConfig(vscode.workspace.getConfiguration)
    messages = new WebviewMessageBus(webview)
    env = { machineId: vscode.env.machineId, ... }
    context = new VSCodeState(context.globalState)
}
```

### Steps

1. Define `KiloRuntime` interface based on minimal surface analysis
2. Create `CLIRuntime` with Bun-native implementations
3. Create `VSCodeRuntime` wrapping real `vscode.*` APIs
4. Replace `require.cache` monkey-patching with dependency injection
5. Migrate `src/` files incrementally (`import * as vscode` -> `import { runtime }`)
6. Handle webview message bus: `postMessage` -> `runtime.messages.send()`
7. Special attention: `DiffViewProvider` (most complex consumer)
8. Delete `packages/vscode-shim/`

### Migration Order (by frequency of use)

| Priority | API | Files | Replacement |
|----------|-----|-------|-------------|
| 1 | `workspace.workspaceFolders` | ~40 | `runtime.env.cwd` |
| 2 | `workspace.getConfiguration()` | ~30 | `runtime.config.get()` |
| 3 | `env.*` | ~20 | `runtime.env.*` |
| 4 | `Uri`, `Position`, `Range` | ~100 | Keep as value types (no shim needed) |
| 5 | `workspace.applyEdit()` | ~10 | `runtime.fs.write()` |
| 6 | `window.*` | ~30 | `runtime.messages.*` or no-ops |
| 7 | `commands.*` | ~15 | Direct dispatch map |
| 8 | `languages.*` | ~6 | Remove or stub |

### Risks

- 251 files must be touched (incremental, but tedious)
- `DiffViewProvider` assumes VSCode's editor model (visibleTextEditors, tabGroups)
- Breaking change for the VSCode extension if interface changes are not backward-compatible

### Payoff

- Shim: 1,500 lines -> ~200 lines of adapter
- Engine becomes testable without any mocks
- Any new frontend (web, mobile, Go TUI) plugs in via the membrane
- No more `Module._resolveFilename` hacks

## Phase 4: Distribution + Polish (Weeks 14-16)

**Goal**: Ship as a single fast-installing package.

### Steps

1. **Bun compile** — `bun build --compile dist/index.ts --outfile kilo` (single binary, ~50-80MB)
2. **Platform packages** — OpenTUI's Zig core ships as platform-specific npm optionalDependencies
3. **Homebrew formula** — `brew install kilocode`
4. **GitHub releases** — Prebuilt binaries per platform
5. **Update CI** — Replace Node.js test matrix with Bun

### Payoff

- Single binary distribution (no npm, no Node.js required)
- `brew install kilocode` or download from releases
- ~200ms startup (Bun compiled + Zig renderer)

## Performance Comparison

| Metric | Current (Node + Ink) | After Migration (Bun + OpenTUI) |
|--------|---------------------|-------------------------------|
| Cold start | ~1s | ~200ms |
| Memory | ~200MB | ~80MB |
| LLM streaming latency | ~450ms | ~6ms |
| Frame rendering | JS string concat | Zig double-buffered cell diff |
| Distribution | npm (needs Node.js 20+) | Single binary |
| Provider coverage | 56 (native) | 56 (unchanged) |
| Shim complexity | 1,500 lines | ~200 lines (membrane) |

## Why Not Go Hybrid (Previous Recommendation)?

The Go TUI + Node engine was recommended when the assumption was "Ink is the bottleneck and you cannot change it within the TypeScript ecosystem." OpenTUI invalidated that assumption.

| Dimension | Go Hybrid | Bun + OpenTUI |
|-----------|-----------|---------------|
| Languages | Go + TypeScript (two codebases) | TypeScript + Zig via FFI (one codebase) |
| IPC | JSON-stdio protocol (must define + maintain) | Zero IPC (in-process) |
| Provider coverage | ~80% via gateway | 100% (unchanged engine) |
| Engine changes | None (black box over IPC) | Incremental (membrane migration) |
| Startup | ~50ms (Go binary) | ~200ms (Bun compiled) |
| Binary size | ~15MB Go + ~80MB Node engine | ~80MB Bun compiled |
| Team skill | Go + TypeScript | TypeScript + minimal Zig (via OpenTUI) |

Go hybrid still wins on raw startup time and binary size. Bun + OpenTUI wins on architecture simplicity, provider coverage, and migration effort.
