# Go LLM Multi-Provider Ecosystem

Research into Go packages that provide LLM provider abstraction layers.

## Executive Summary

Go does not have a direct LiteLLM equivalent with 100+ provider coverage.
Two categories exist: embedded Go SDKs and Go-written proxy gateways.

## Tier 1: Production-Viable

### langchaingo (github.com/tmc/langchaingo)

- **Stars**: 8,695 | **Contributors**: 180 | **License**: MIT
- **Providers**: ~13 (OpenAI, Anthropic, Bedrock, Gemini, Cohere, Mistral, Ollama, Cloudflare, HuggingFace, Llamafile, Maritaca, Watsonx, Ernie)
- **Streaming**: Yes | **Tool use**: Yes (major providers) | **Structured output**: Partial
- **Assessment**: Most mature Go LLM library. Does NOT cover Groq, DeepSeek, Cerebras, Together AI, Perplexity, Fireworks, xAI

### Bifrost (github.com/maximhq/bifrost)

- **Stars**: 2,401 | **Contributors**: 40 | **License**: Apache-2.0
- **Architecture**: HTTP gateway + embeddable Go SDK
- **Providers**: 15+ direct + 1,000+ via OpenAI-compatible routing
- **Features**: Streaming, MCP client, structured output, load balancing, semantic caching, fallback/retry
- **Performance**: 50x faster than LiteLLM, ~11 microsecond overhead at 5K RPS
- **Assessment**: Closest to LiteLLM — as an infrastructure gateway, not an application SDK

## Tier 2: Promising but Limited

### maruel/genai

- **Stars**: ~23 (very new, single author) | **Providers**: 19
- **Providers**: Anthropic, Baseten, Cerebras, Cloudflare, Cohere, DeepSeek, Gemini, Groq, HuggingFace, llama.cpp, Mistral, Ollama, OpenAI, Perplexity, Together AI, more
- **Architecture**: Raw HTTP, no SDK dependencies, idiomatic Go generics
- **Assessment**: Architecturally cleanest. Broadest native provider coverage in Go. Too new for production

### teilomillet/gollm

- **Stars**: 636 | **Providers**: 6 + OpenRouter
- Higher-level prompt engineering library. No confirmed tool calling

### modfin/bellman

- **Stars**: 65 | **Providers**: 5 (OpenAI, Anthropic, Vertex, Ollama, VoyageAI)
- Clean interface design. Includes self-hosted proxy mode

## Coverage Gap Analysis

Union of langchaingo + maruel/genai covers ~25-28 distinct providers.
Getting to 56 requires:
1. Bifrost/OpenRouter as gateway meta-provider (100+ models, one endpoint)
2. OpenAI-compatible base URL pattern (~30 of 56 providers expose this)

## Verdict

| Strategy | Go Readiness |
|----------|-------------|
| Full SDK parity (56 integrations) | Not mature |
| Gateway architecture (Bifrost) | Viable today |
| Top 20 providers + OpenAI-compat fallback | Viable (~80% coverage) |
| Production-grade with SLA | langchaingo only |

Go ecosystem is ~12-18 months behind TypeScript/Python for LLM multi-provider abstraction.
