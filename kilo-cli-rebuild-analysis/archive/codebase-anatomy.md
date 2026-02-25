# Kilo Code Codebase Anatomy

**Source**: `/Volumes/atlas/kilocode` (commit 976993e883)
**Repo**: `Kilo-Org/kilocode`

## Monorepo Structure

```
kilocode/                          # pnpm workspace + Turbo
├── src/                           # 341K LoC — Shared VSCode extension core
│   ├── api/                       # LLM provider integrations
│   │   ├── providers/             # 56 providers (anthropic, openai, gemini, ollama, etc.)
│   │   │   ├── fetchers/          # HTTP/streaming helpers
│   │   │   └── utils/             # Timeout, retry, token counting
│   │   ├── transform/             # Message format transformers
│   │   └── index.ts               # Provider registry
│   ├── core/                      # Agent engine
│   │   ├── tools/                 # 25+ tool implementations
│   │   │   ├── EditFileTool.ts
│   │   │   ├── ExecuteCommandTool.ts
│   │   │   ├── BrowserActionTool.ts
│   │   │   ├── CodebaseSearchTool.ts
│   │   │   ├── ReadFileTool.ts
│   │   │   ├── WriteToFileTool.ts
│   │   │   ├── SearchFilesTool.ts
│   │   │   ├── NewTaskTool.ts     # Subagent delegation
│   │   │   ├── UseMcpToolTool.ts  # MCP tool proxy
│   │   │   └── ...
│   │   ├── task/                  # Task lifecycle, orchestration
│   │   ├── context/               # Context window management
│   │   ├── context-management/    # Token budgeting, truncation
│   │   ├── prompts/               # System prompt generation
│   │   ├── diff/                  # Diff application, conflict resolution
│   │   ├── checkpoints/           # Git-based undo/redo
│   │   ├── condense/              # Conversation condensation
│   │   └── kilocode/              # Kilo-specific features (agent-manager, sessions)
│   ├── integrations/              # External service integrations
│   ├── extension/                 # VSCode extension host
│   └── shared/                    # Types, utilities shared across surfaces
│
├── cli/                           # 67K LoC — Terminal CLI
│   ├── src/
│   │   ├── ui/                    # Ink (React) TUI components
│   │   │   ├── App.tsx            # Root component
│   │   │   ├── UI.tsx             # Main layout
│   │   │   ├── components/        # Reusable widgets
│   │   │   │   ├── CommandInput.tsx
│   │   │   │   ├── MarkdownText.tsx
│   │   │   │   ├── StatusBar.tsx
│   │   │   │   ├── ApprovalMenu.tsx
│   │   │   │   ├── MultilineTextInput.tsx
│   │   │   │   └── ThinkingAnimation.tsx
│   │   │   ├── messages/          # Message rendering
│   │   │   ├── providers/         # React context (KeyboardProvider)
│   │   │   └── utils/             # Syntax highlight, terminal capabilities
│   │   ├── state/                 # Jotai atoms
│   │   │   ├── atoms/             # State management (config, ci, keyboard, etc.)
│   │   │   └── hooks/             # React hooks
│   │   ├── services/              # Extension service shim, telemetry, logs
│   │   ├── config/                # CLI config persistence
│   │   ├── auth/                  # Auth wizard
│   │   ├── commands/              # Subcommands (models API)
│   │   ├── parallel/              # Parallel mode (git worktree-based)
│   │   ├── constants/             # Keyboard codes, modes, providers
│   │   └── cli.ts                 # Main CLI class (775 lines)
│   └── integration-tests/
│
├── packages/
│   ├── agent-runtime/             # Headless agent (no UI dependency)
│   ├── core-schemas/              # Zod schemas shared across packages
│   ├── vscode-shim/               # VSCode API polyfill for CLI
│   ├── ipc/                       # Inter-process communication
│   ├── cloud/                     # Kilo cloud service client
│   ├── telemetry/                 # PostHog telemetry
│   ├── types/                     # Shared TypeScript types
│   ├── evals/                     # Evaluation framework
│   └── build/                     # Build tooling
│
├── webview-ui/                    # VSCode webview (React)
├── jetbrains/                     # JetBrains plugin (Kotlin, 31K LoC)
├── apps/
│   ├── cli/                       # CLI app wrapper
│   ├── web-roo-code/              # Web version
│   ├── kilocode-docs/             # Documentation site
│   ├── playwright-e2e/            # E2E tests
│   └── storybook/                 # Component storybook
└── scripts/                       # Build/release scripts
```

## CLI TUI Stack

```
Commander (arg parsing)
    -> CLI class (cli.ts — lifecycle orchestration)
        -> Jotai store (reactive state)
        -> ExtensionService (vscode-shim bridge)
        -> Ink render() (React -> terminal output)
            -> App.tsx -> UI.tsx -> Components
```

Key technology choices:
- **Ink 6.6** — React renderer for terminals (handles layout, colors, input)
- **Jotai 2.16** — Atomic state management (replaces VSCode's event emitters)
- **Commander 14** — CLI argument parsing
- **Shiki** — Syntax highlighting in terminal
- **Chalk** — Terminal colors
- **marked + marked-terminal** — Markdown rendering

## Provider Count (56)

anthropic, anthropic-vertex, baseten, bedrock, cerebras, chutes, claude-code,
corethink, deepinfra, deepseek, doubao, fake-ai, featherless, fireworks, gemini,
glama, groq, huggingface, human-relay, inception, io-intelligence,
kilocode, kilocode-openrouter, lite-llm, lm-studio, minimax, mistral, moonshot,
nano-gpt, native-ollama, openai-codex, openai-compatible, openai-native,
openai-responses, openai, openrouter, ovhcloud, qwen-code, requesty, roo,
router-provider, sambanova, sap-ai-core, synthetic, unbound,
vercel-ai-gateway, vertex, virtual-quota-fallback, vscode-lm, xai, zai

## Tool Count (25+)

EditFile, ExecuteCommand, ReadFile, WriteToFile, SearchFiles, ListFiles,
CodebaseSearch, BrowserAction, ApplyDiff, MultiApplyDiff, ApplyPatch,
SearchAndReplace, SearchReplace, FetchInstructions, GenerateImage,
AskFollowupQuestion, AttemptCompletion, NewTask, SwitchMode,
RunSlashCommand, UpdateTodoList, UseMcpTool, AccessMcpResource

## VSCode Shim Layer

The `packages/vscode-shim/` polyfills these VSCode APIs for CLI use:
- `vscode.workspace` — file system access
- `vscode.window` — output channels, notifications
- `vscode.commands` — command registration
- `vscode.Uri` — URI handling
- `vscode.Position/Range/Selection` — text document model

This is the key coupling point. The entire `src/` core imports `vscode` types,
and the shim makes this work outside VSCode.

## Dependency Weight

CLI `package.json` declares 139 runtime dependencies. Notable heavy ones:
- `puppeteer-core` + `puppeteer-chromium-resolver` — browser automation
- `tiktoken` — WASM-based token counting
- `tree-sitter-wasms` + `web-tree-sitter` — code parsing
- `@vscode/ripgrep` — file search binary
- `jsdom` — HTML parsing
- `shiki` — syntax highlighting (loads grammars)
- `xlsx`, `mammoth`, `pdf-parse` — document parsing

These contribute to the ~800ms-1.5s cold start time.
