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
  - Gemini 3 thought signatures preserved across tool-call round trips, including parallel calls,
    which the API requires when a model turn is replayed in the conversation history.
  - Multimodal input through `generate` — images, PDFs, and Gemini File API references.
  - API-key authentication via the `x-goog-api-key` header.
- `GEMINI_4_ARGON` and `GEMINI_3_8_FLASH` models. `GEMINI_3_8_FLASH` is now the recommended default.
- Optional `thinkingLevel` (`LOW`, `MEDIUM`, `HIGH`) on `ModelProvider`, sent as
  `generationConfig.thinkingConfig.thinkingLevel` from both `chat` and `generate`.
- A warning logged when `temperature` is set on `GEMINI_4_ARGON` or `GEMINI_3_8_FLASH`, which
  deprecate it in favour of `thinkingLevel`.

### Removed
- The retired `GEMINI_2_5_PRO`, `GEMINI_2_5_FLASH` and `GEMINI_2_5_FLASH_LITE` models.
