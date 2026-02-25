# Claude Code Tech Stack

## Architecture

| Component | Technology |
|-----------|-----------|
| Language | TypeScript |
| Terminal UI | React + Ink (custom renderer) |
| Layout engine | Yoga (Meta) |
| Build tool | Bun |
| Runtime | Node.js (distributed via npm) |
| Self-authorship | ~90% written by Claude Code |
| Release cadence | ~5 releases per engineer per day |

## "On Distribution" Philosophy

Anthropic chose TypeScript + React because Claude is already excellent at writing
TypeScript and React. This creates a virtuous cycle: Claude writes 90% of Claude Code,
enabling rapid iteration.

The stack was chosen for **model capability**, not runtime performance.

## Custom Renderer

Anthropic found Ink's built-in renderer insufficient for their ~5ms ANSI-write budget
and rewrote it from scratch while keeping React as the component model.

Pipeline (from Chris Lloyd, Jan 2026):
1. React constructs scene graph
2. Elements laid out
3. Rasterized to 2D screen buffer
4. Diffed against previous frame
5. Minimal ANSI sequences generated from diff

~16ms frame budget, ~5ms for scene graph to ANSI written.

## Comparison to Kilo

| Dimension | Claude Code | Kilo Code CLI |
|-----------|-------------|---------------|
| Runtime | Node.js | Node.js |
| TUI | React + custom renderer | React + Ink (stock) |
| Build | Bun | esbuild + Turbo |
| LLM providers | 1 (Claude API) | 56 |
| State management | Internal | Jotai atoms |
| VSCode shim | N/A (standalone) | 1,500 lines |

## Implication for Rebuild Analysis

If the AI writes 90% of the code, the language the AI is best at writing matters
more than the language with the best TUI framework. This favors TypeScript for
AI-heavy codebases — strengthening the case for Bun + OpenTUI over a Go rewrite.

Source: [How Claude Code is built — Pragmatic Engineer](https://newsletter.pragmaticengineer.com/p/how-claude-code-is-built)
