# Sources

## Primary Sources

- [Kilo-Org/kilocode](https://github.com/Kilo-Org/kilocode) — Main repo (commit 976993e883, cloned at `/Volumes/atlas/kilocode`)
- [anomalyco/opentui](https://github.com/anomalyco/opentui) — OpenTUI repo (v0.1.81, cloned at `/Volumes/atlas/opentui`)

## Press and Context

- [Kilo CLI 1.0 — VentureBeat](https://venturebeat.com/orchestration/kilo-cli-1-0-brings-open-source-vibe-coding-to-your-terminal-with-support) — Launch coverage, "Agentic Anywhere" strategy
- [Kilo CLI reshapes terminal coding — AI CERTs](https://www.aicerts.ai/news/kilo-cli-release-reshapes-terminal-coding-workflows/) — Feature overview
- [How Claude Code is built — Pragmatic Engineer](https://newsletter.pragmaticengineer.com/p/how-claude-code-is-built) — Stack, "on distribution" philosophy, 90% self-written
- [AI CLI Tools Comparison — Mervin Praison](https://mer.vin/2025/12/ai-cli-tools-comparison-why-openai-switched-to-rust-while-claude-code-stays-with-typescript/) — TypeScript vs Rust for CLI tools

## TUI Frameworks

- [Bubbletea](https://github.com/charmbracelet/bubbletea) — Go TUI framework (Elm architecture)
- [Ratatui](https://github.com/ratatui/ratatui) — Rust TUI framework
- [Ink](https://github.com/vadimdemedes/ink) — React for terminals (used by Kilo CLI, Claude Code)
- [OpenTUI](https://github.com/anomalyco/opentui) — Zig core + React/Solid reconciler (used by OpenCode)
- [Rezi](https://rezitui.dev/) — TypeScript TUI with native C engine (alpha, 7-59x faster than Ink)
- [lazygit](https://github.com/jesseduffield/lazygit) — Panel-based Git TUI (Bubbletea)

## Terminal Emulators

- [Ghostty](https://github.com/ghostty-org/ghostty) — GPU-accelerated terminal (Zig)
- [Warp](https://www.warp.dev/) — AI-native terminal (Rust)

## VSCode GPU Rendering

- [VSCode GPU renderer tracking issue #221145](https://github.com/microsoft/vscode/issues/221145) — WebGPU editor renderer
- [VSCode GPU test plan #234762](https://github.com/microsoft/vscode/issues/234762) — First public testing (Nov 2024)
- [Zed blade-to-wgpu PR #46758](https://github.com/zed-industries/zed/pull/46758) — Merged Feb 13, 2026
- [GPUI architecture analysis](https://kaelan.fyi/research/gpui-zed-renderer/) — Zed's 120fps GPU-accelerated UI

## Go LLM Ecosystem

- [langchaingo](https://github.com/tmc/langchaingo) — 8.7K stars, 13 providers, production-grade
- [Bifrost](https://github.com/maximhq/bifrost) — 2.4K stars, Go AI gateway, 50x faster than LiteLLM
- [maruel/genai](https://github.com/maruel/genai) — 19 providers, raw HTTP, idiomatic Go
- [teilomillet/gollm](https://github.com/teilomillet/gollm) — 636 stars, prompt engineering library

## OpenCode (OpenTUI Consumer)

- [anomalyco/opencode](https://github.com/anomalyco/opencode) — 110K stars, primary OpenTUI consumer
- [OpenCode RFC #13027](https://github.com/anomalyco/opencode/issues/13027) — Enhanced rendering RFC (75x streaming improvement)

## Bun + Zig Stack

- [Bun](https://bun.sh/) — JavaScript/TypeScript runtime built on Zig + JavaScriptCore
- [bun:ffi docs](https://bun.sh/docs/api/ffi) — Zero-overhead FFI to C ABI shared libraries

## Related Research Hubs

- `../kilo-cli-vs-claude-code/` — Competitive analysis, ACF portability, Agent Harness Protocol
- `../kilo-code-hiring/` — Team composition analysis
- `../python-go-rust-migration/` — Language migration patterns
