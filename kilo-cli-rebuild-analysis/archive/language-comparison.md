# Language Comparison: Rust vs Go vs TypeScript

## Evaluation Matrix

| Dimension | Go | Rust | TypeScript (current) |
|-----------|-----|------|---------------------|
| **Startup time** | ~50ms | ~5ms | ~800ms-1.5s |
| **Memory usage** | ~20-40MB | ~5-15MB | ~150-300MB |
| **Binary distribution** | Single binary, CGO optional | Single binary | Requires Node.js 20+ |
| **TUI framework** | Bubbletea (excellent, battle-tested) | Ratatui (excellent, active community) | Ink (good, React overhead) |
| **LLM SDK availability** | Good (sashabaranov/go-openai, anthropic-sdk-go) | Emerging (async-openai, anthropic-rs) | Excellent (first-party SDKs) |
| **Concurrency model** | Goroutines (excellent for I/O) | async/tokio (excellent, more complex) | Event loop (adequate) |
| **Tree-sitter bindings** | go-tree-sitter (mature) | tree-sitter crate (excellent) | web-tree-sitter WASM (current) |
| **Build time** | Seconds | Minutes (incremental: seconds) | Seconds (esbuild) |
| **Error handling** | Explicit (if err) | Explicit (Result<T,E>) | Try-catch (implicit) |
| **Team velocity** | Fast, large talent pool | Slower, ownership learning curve | Fastest (existing team) |
| **Cross-platform** | Excellent (GOOS/GOARCH) | Excellent (target triples) | Excellent (Node.js) |
| **FFI with Node.js** | Easy (stdio JSON, CGO) | Easy (napi-rs, stdio JSON) | N/A (native) |
| **Package ecosystem** | Moderate (stdlib-heavy) | Growing (crates.io) | Massive (npm) |

## Scoring (weighted by rebuild-relevance)

Weights: Startup=15%, Memory=10%, Distribution=15%, TUI=15%, LLM SDKs=10%,
Concurrency=10%, Velocity=15%, Cross-platform=5%, FFI=5%

| Dimension (weight) | Go | Rust | TypeScript |
|---------------------|-----|------|------------|
| Startup (15%) | 8 | 10 | 3 |
| Memory (10%) | 8 | 10 | 3 |
| Distribution (15%) | 9 | 9 | 4 |
| TUI framework (15%) | 10 | 9 | 7 |
| LLM SDKs (10%) | 7 | 5 | 10 |
| Concurrency (10%) | 9 | 9 | 6 |
| Velocity (15%) | 8 | 5 | 10 |
| Cross-platform (5%) | 9 | 9 | 9 |
| FFI with engine (5%) | 8 | 8 | 10 |
| **Weighted total** | **8.4** | **7.9** | **6.2** |

## Go Advantages for This Use Case

1. **Bubbletea is lazygit-proven** — Panel-based TUI with vim keybindings, streaming updates, responsive layout
2. **Goroutines for concurrent tools** — Stream LLM output while executing shell commands while monitoring file changes
3. **Single binary** — `brew install kilo` or `go install`, no Node.js dependency for end users
4. **Fast iteration** — Compile in seconds, refactor with confidence (type-safe but not ownership-complex)
5. **Charmbracelet ecosystem** — Lip Gloss (styling), Bubbles (components), Wish (SSH TUIs), Huh (forms)

## Rust Advantages for This Use Case

1. **Ratatui community** — Active, well-documented, growing fast
2. **Memory safety without GC** — Matters for long-running agent sessions
3. **Smallest binary + fastest startup** — Best native feel
4. **napi-rs** — Could embed Node.js directly if needed
5. **WASM target** — Same TUI could compile to browser (future web version)

## TypeScript Advantages (status quo)

1. **Zero rewrite cost** — Already works, team knows it
2. **First-party LLM SDKs** — Anthropic, OpenAI, Google all ship TypeScript first
3. **Shared code with VSCode extension** — One change updates both surfaces
4. **npm ecosystem** — 139 deps already integrated and working
5. **Ink is adequate** — React mental model, component reuse with webview

## Why Not Rust (for this specific case)

- The agent logic changes weekly as AI product features evolve
- Ownership model adds friction to rapid prototyping of new provider integrations
- The LLM SDK ecosystem in Rust lags TypeScript by ~6-12 months
- The team maintaining this likely has more TS/Go experience than Rust experience

## Why Not Stay TypeScript

- 800ms-1.5s cold start is noticeable for every invocation
- 150-300MB memory for what should be a lightweight CLI
- `npm install -g` is friction compared to single binary
- Ink's React rendering model is overkill for a TUI (re-renders entire component tree)
- 139 dependencies is a supply chain risk surface
