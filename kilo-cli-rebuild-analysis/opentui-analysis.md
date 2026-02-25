# OpenTUI Architecture Analysis

**Repo**: anomalyco/opentui (previously sst/opentui)
**Version**: v0.1.81 (Feb 2026)
**Stars**: 8,798
**Languages**: TypeScript 66%, Zig 30%, MDX 2%, WGSL <1%

## Core Architecture

```
TypeScript (React/Solid reconciler)
    -> Yoga layout (JS, flexbox)
    -> Renderable tree (TS objects)
    -> C ABI calls via bun:ffi
    -> Zig native core (libopentui.dylib)
        -> Double-buffered cell diff
        -> ANSI escape output
        -> stdout
```

## What Zig Handles (Performance-Critical Path)

| Subsystem | Zig File | Responsibility |
|-----------|----------|----------------|
| Renderer | renderer.zig | Double-buffered cell diffing, ANSI output, FPS loop |
| Cell buffer | buffer.zig | OptimizedBuffer — 2D cell array, alpha blending, scissor rects |
| Text buffer | text-buffer.zig | Rope-based Unicode storage, word-wrap cache, syntax highlights |
| Edit buffer | edit-buffer.zig | Full editor state (undo/redo, cursor, selections) |
| Grapheme | grapheme.zig | Grapheme cluster segmentation via uucode |
| UTF-8 / width | utf8.zig | wcwidth vs Unicode mode 2026 dispatch |
| ANSI | ansi.zig | RGBA as [4]f32, text attributes, hyperlink IDs |
| Native span feed | native-span-feed.zig | Zero-copy streaming (chunk ring + span ring) |
| Hit grid | (in renderer) | Mouse click routing by renderable ID |
| Terminal | terminal.zig | Capability detection (Kitty, Sixel, SGR, OSC52) |
| Event bus | event-bus.zig | C-callback event delivery Zig -> TS |

## What Stays in TypeScript

- Layout computation (Yoga — same as Ink, not replaced)
- React/Solid reconciler layer
- Renderable class hierarchy (TextRenderable, BoxRenderable, etc.)
- Keyboard input parsing
- Render loop scheduling
- Optional 3D/WebGPU pipeline
- Tree-sitter WASM integration
- All application-level logic

## React Reconciler (@opentui/react)

Uses `react-reconciler` v0.32 with ConcurrentRoot mode.

Component catalogue:

```
box, text, code, diff, markdown, input, select, textarea,
scrollbox, ascii-font, tab-select, line-number,
span, br, b, strong, i, em, u, a
```

Extensible via `extend()` — OpenCode adds custom renderables.
React DevTools supported (`injectIntoDevTools()`).

Bridge flow: React VDOM -> reconciler commits -> imperative Renderable mutation
-> requestRender() -> Zig diff engine -> ANSI output.

## C ABI Surface (~100 exported functions)

Grouped by domain:
- Lifecycle: createRenderer, destroyRenderer, render, resize
- Callbacks: setLogCallback, setEventCallback
- Buffer: create/destroy, clear, resize, drawText, setCell, fillRect, drawBox
- Scissor/opacity: push/pop scissor rects, push/pop opacity
- Terminal: setCursorPosition, setTerminalTitle, getCapabilities
- Hit grid: addToHitGrid, checkHit, clearHitGrid
- Native span feed: create/destroy, write, drain (zero-copy streaming)
- Text/edit buffer: ~50 functions for rope-based text editing
- Links: linkAlloc, linkGetUrl, attributesWithLink

## NativeSpanFeed (Zero-Copy LLM Streaming)

The killer feature for AI CLI tools. Architecture:

```
LLM token arrives
    -> feed.write(tokenBytes) — JS writes directly to Zig chunk ring
    -> Zig processes spans from ring buffer
    -> Zig renders directly to cell buffer
    -> Zig diffs and emits minimal ANSI
```

No JS string intermediary. No React reconciliation for streaming text.
OpenCode RFC measured: 450ms -> 6ms for LLM streaming (75x improvement).

## WGSL / GPU (Optional)

One compute shader: `supersampling.wgsl` for terminal-native 3D rendering.
Three.js renders to GPU texture -> compute shader converts to terminal cells.
Not used in the core TUI path. Strictly optional (`bun-webgpu`, `three` are optionalDependencies).

## Platform Packages

Prebuilt Zig shared libraries shipped as npm optional dependencies:

```
@opentui/core-darwin-arm64
@opentui/core-darwin-x64
@opentui/core-linux-x64
@opentui/core-linux-arm64
@opentui/core-win32-x64
@opentui/core-win32-arm64
```

## Bun Dependency

OpenTUI uses `bun:ffi` (`dlopen`) to call the Zig shared library.
This is Bun-specific — does NOT work on Node.js (no `bun:ffi`).
Migrating to OpenTUI implicitly requires migrating to Bun as runtime.
