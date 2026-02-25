# VSCode GPU-Accelerated Rendering

## Current State

| Layer | Renderer | GPU? | Status |
|-------|----------|------|--------|
| Terminal | xterm.js WebGL2 | Yes | Stable, default since 2024 |
| Editor text | WebGPU | Experimental | Opt-in since Nov 2024, pre-release as of Jan 2026 |
| IDE chrome | DOM/HTML | No | No GPU plans |

## Editor GPU Renderer

**Tracking issue**: [microsoft/vscode#221145](https://github.com/microsoft/vscode/issues/221145) (opened July 2024)

Architecture:
- WebGPU (not WebGL2) — modern compute/shader API
- Vertex + fragment shaders for glyph rendering via texture atlas
- Pre-allocates CPU-side buffer for ~3,000 lines x 200 columns (~7.2MB GPU memory)
- Scrolling: only scroll offset uniform updates per frame
- Double buffering (GPU locks buffers until rendering completes)
- DOM fallback for lines the GPU renderer cannot handle (yellow gutter indicator)

Enable via:
```json
"editor.experimentalGpuAcceleration": "on"
```

## Terminal GPU Renderer

xterm.js WebGL2 is the default renderer. Canvas 2D fallback removed in VSCode 1.90 (May 2024).

Architecture:
- Typed array of GPU commands (texture index, fg/bg color, position)
- Single GPU upload per frame
- Texture atlas with pre-rasterized glyphs
- Falls back to DOM when WebGL unavailable

## VSCode vs Zed

| Dimension | VSCode | Zed |
|-----------|--------|-----|
| GPU scope | Editor text only (experimental) | Entire UI (120fps) |
| API | WebGPU via Electron/Chromium | Metal/wgpu (native) |
| Rendering model | Hybrid GPU + DOM | "Game engine" (full redraws each frame) |
| Memory | ~1-2GB (Electron) | Significantly lower |
| Extension impact | DOM decorations force fallback | Extension API still maturing |

Zed switched from Blade to wgpu (Feb 13, 2026) for Linux, aligning with Rust ecosystem.

## Relevance to Kilo CLI

VSCode GPU rendering benefits the **extension** (runs inside VSCode). The **CLI** (standalone terminal app) does not benefit — it outputs ANSI escape codes that the user's terminal emulator renders. The terminal emulator (Ghostty, Kitty, iTerm2) handles GPU rendering of those codes.

Sources:
- [VSCode GPU renderer issue](https://github.com/microsoft/vscode/issues/221145)
- [First test plan](https://github.com/microsoft/vscode/issues/234762)
- [Zed wgpu migration PR](https://github.com/zed-industries/zed/pull/46758)
