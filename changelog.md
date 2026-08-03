# Change Log

This file documents all significant changes made to the Ballerina `ai.google.gemini` package across releases.

## [Un-released]

### Added
- Initial implementation of the Gemini connector for the `ballerina/ai` framework.
  - `ModelProvider` — `chat` and structured `generate` backed by Gemini's `:generateContent` REST API.
  - `EmbeddingProvider` — `embed` and `batchEmbed` backed by `:embedContent` / `:batchEmbedContents`.
  - Native function calling (tool use) and structured output through Gemini's standard-JSON-Schema
    fields (`parametersJsonSchema` / `responseJsonSchema`), which accept `$ref`, `$defs`,
    `additionalProperties` and `prefixItems` without modification.
  - Multimodal input through `generate` — images, PDFs, and Gemini File API references.
  - API-key authentication via the `x-goog-api-key` header.
