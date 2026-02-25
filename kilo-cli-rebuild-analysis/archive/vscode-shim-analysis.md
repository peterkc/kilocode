# VSCode Shim Deep Dive

Analysis of how Kilo CLI fakes the VSCode API to run the extension engine headlessly.

## Architecture

```
CLI process
  ├── packages/vscode-shim/         1,500 lines of fake VSCode API
  ├── packages/agent-runtime/
  │   ├── host/ExtensionHost.ts     Patches require('vscode') at load time
  │   └── host/VSCode.ts            DUPLICATE of vscode-shim (self-contained)
  └── src/ (341K LoC)               Imports 'vscode' — gets the shim
```

The key mechanism in `ExtensionHost.loadExtension()`:

```typescript
ModuleClass._resolveFilename = (request) => {
    if (request === 'vscode') return 'vscode-mock'
    return originalResolveFilename(...)
}
require.cache['vscode-mock'] = { exports: this.vscodeAPI }
this.extensionModule = require(extensionPath)
```

## What's Real vs Stubbed

### Fully Implemented (real behavior)

- `workspace.workspaceFolders` — configured from cwd
- `workspace.getConfiguration()` — file-backed JSON with runtime overrides
- `workspace.applyEdit()` — writes WorkspaceEdit operations to disk via Node.js fs
- `workspace.openTextDocument()` — reads real files from disk
- `workspace.fs.*` — FileSystemAPI wrapping Node.js fs
- `window.showTextDocument()` — maintains in-memory visibleTextEditors
- `window.registerWebviewViewProvider()` — connects to ExtensionHost message bus
- `commands.registerCommand() / executeCommand()` — real dispatch map
- `env.*` (machineId, sessionId, language, shell) — configurable
- `ExtensionContext` with `globalState` / `secrets` — file-backed Memento
- `Uri`, `Position`, `Range`, `Selection`, `EventEmitter` — full implementations

### Stubbed (no-ops)

- `workspace.createFileSystemWatcher()` — events never fire (no hot-reload)
- `workspace.findFiles()` — always returns []
- `window.createTerminal()` — stub (CLI uses execa instead, gated by KILO_CLI_MODE)
- `env.clipboard` — stub (gated by terminalShellIntegrationDisabled)
- `languages.getDiagnostics()` — always empty (no pre/post diff diagnostics)
- All `register*Provider()` — no-ops

## The Real Bottleneck: Webview Message Bus

All engine orchestration flows through fake `webview.postMessage`:

```
VSCode world:  Extension <-> Webview (postMessage/onMessage)
CLI world:     ExtensionService <-> Jotai Store <-> Ink Components
```

`registerWebviewViewProvider()` is the activation trigger. The mock webview's
`postMessage` / `onDidReceiveMessage` wiring is the actual control plane.

## Minimal Required Surface

251 files import `vscode`, but the hot path needs only:

| API | Why | Lines of Shim |
|-----|-----|---------------|
| File ops (applyEdit, openTextDocument, fs) | Tool execution | ~50 |
| Config (getConfiguration, globalState) | Settings persistence | ~40 |
| Message bus (webview postMessage) | Task orchestration | ~30 |
| Identity (env.machineId, shell, language) | System prompt | ~10 |
| Value types (Uri, Position, Range, EventEmitter) | Data types | ~70 |
| **Total** | | **~200** |

The remaining ~1,300 lines are no-ops, stubs, and rarely-used UI shims.

## Duplicate Code Issue

`agent-runtime/src/host/VSCode.ts` (92KB) is a COMPLETE DUPLICATE of `packages/vscode-shim/`.
The agent-runtime is self-contained and does not import from `@roo-code/vscode-shim`.
This means two copies of the shim must be maintained in sync.
